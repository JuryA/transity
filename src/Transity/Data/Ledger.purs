module Transity.Data.Ledger where
import Prelude
  ( class Show, class Eq, bind, compare, identity, map, pure, show
  , (#), ($), (+), (<#>), (<>), (||), (==), (>>=)
  )

import Control.Alt ((<|>))
import Control.Monad.Except (runExcept)
import Data.Argonaut.Core (toObject, Json)
import Data.Argonaut.Decode (decodeJson)
import Data.Argonaut.Decode.Class (class DecodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Array (concat, groupBy, sort, sortBy, uncons, (!!))
import Data.Array as Array
import Data.DateTime (DateTime)
import Data.Foldable (all)
import Data.Function (flip)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.HeytingAlgebra (not)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe, fromMaybe)
import Data.Monoid (power)
import Data.Newtype (unwrap)
import Data.Rational (toNumber)
import Data.Result (Result(..), toEither, fromEither)
import Data.Set as Set
import Data.String (joinWith)
import Data.Traversable (fold, foldr, intercalate, sequence)
import Data.Tuple (Tuple(..))
import Data.Unit (Unit, unit)
import Data.YAML.Foreign.Decode (parseYAMLToJson)
-- import Debug.Trace
import Foreign (renderForeignError)
import Transity.Data.Account (Account(..))
import Transity.Data.Account as Account
import Transity.Data.Amount (Amount(..), Commodity)
import Transity.Data.Amount as Amount
import Transity.Data.CommodityMap
  ( CommodityMap
  , addAmountToMap
  , subtractAmountFromMap
  , isCommodityMapZero
  , isCommodityZero
  )
import Transity.Data.Entity (Entity(..), toTransfers)
import Transity.Data.Transaction (Transaction(..))
import Transity.Data.Transaction as Transaction
import Transity.Data.Transfer (Transfer(..), negateTransfer)
import Transity.Utils
  ( getFieldMaybe
  , getObjField
  , mergeWidthRecords
  , utcToIsoString
  , utcToIsoDateString
  , widthRecordZero
  , ColorFlag(..)
  , WidthRecord
  )


-- | List of all transactions
newtype Ledger = Ledger
  { owner :: String
  , entities :: Maybe (Array Entity)
  , transactions :: Array Transaction
  }

derive instance genericLedger :: Generic Ledger _
derive newtype instance eqLedger :: Eq Ledger

instance showLedger :: Show Ledger where
  show = genericShow

instance decodeLedger :: DecodeJson Ledger where
  decodeJson json = toEither $ decodeJsonLedger json


decodeJsonLedger :: Json -> Result String Ledger
decodeJsonLedger json = do
  object       <- maybe (Error "Ledger is not an object") Ok (toObject json)
  owner        <- object `getObjField` "owner"
  entities     <- object `getFieldMaybe` "entities"
  transactions <- object `getObjField` "transactions"
  pure $ Ledger {owner, entities, transactions}


verifyAccounts :: Ledger -> Result String Ledger
verifyAccounts wholeLedger@(Ledger ledger) =
  let
    definedAccounts = Set.fromFoldable $ concat
      $ (fromMaybe [] ledger.entities) <#>
        (\(Entity {id, accounts}) -> [id] <>
          ((fromMaybe [] accounts) <#>
            (\(Account account) -> id <> ":" <> account.id))
        )
    usedAccounts =
      (ledger.transactions <#> \(Transaction {transfers}) -> transfers)
      # concat
      # map (\(Transfer {from, to}) -> [from, to])
      # concat
      # Set.fromFoldable
    undefinedAccounts :: Array String
    undefinedAccounts = Set.toUnfoldable $
      usedAccounts `Set.difference` definedAccounts
  in
    case undefinedAccounts of
      [] -> Ok wholeLedger
      _ -> Error $
        "Following accounts were not declared, "
        <> "but still used for transfers:\n\n"
        <> "entities:"
        <> joinWith "" (undefinedAccounts <#> ("\n  - id: " <> _))
        <> "\n\n"
        <> "Please add or rename the missing accounts "
        <> "to the entities section to fix this error"


isAmountInMapZero :: BalanceMap -> String -> Commodity -> Boolean
isAmountInMapZero balanceMap accountId commodity =
  let
    comMap = Map.lookup accountId balanceMap
  in
    fromMaybe false $
      comMap <#> (flip isCommodityZero) commodity


verifyBalances :: BalanceMap -> Array Transfer -> Result String Unit
verifyBalances balanceMap balancingTransfers =
  case uncons balancingTransfers of
    Just {head: transfHead@(Transfer tfHeadRec), tail: transfTail} ->
      let
        newBal = balanceMap `addTransfer` transfHead
        getCommodity {amount: Amount _ commodity} = commodity
      in
        if tfHeadRec.note == Just "___BALANCE___"
        then
          if not $ isAmountInMapZero
              newBal tfHeadRec.from (getCommodity tfHeadRec)
          then Error(
              "Transactions don't match up with verification balances\n\n"
              <> "The account '" <> tfHeadRec.from
              <> "'' in following balance map is not zero:\n"
              <> (show newBal)
              <> "\n\n"
            )
          else verifyBalances newBal transfTail
        else
          verifyBalances newBal transfTail
    Nothing ->
      Ok unit


verifyLedgerBalances :: Ledger -> Result String Ledger
verifyLedgerBalances wholeLedger@(Ledger ledger) =
  let
    balancingTransfers = (fromMaybe [] ledger.entities)
      <#> toTransfers
      # fold
      -- Label the balancing transfers to tell them apart from normal transfers
      -- FIXME: Really hacky and should be solved with a wrapper datatype
      <#> (\(Transfer tf) -> Transfer tf {note = Just "___BALANCE___"})
    transxTransfers = Transaction.toTransfers ledger.transactions
    combined = (balancingTransfers <> transxTransfers)
      # sortBy (\(Transfer transfA) (Transfer transfB) ->
                    compare transfA.utc transfB.utc)
    result = verifyBalances Map.empty combined
  in
    if ledger.entities == Nothing || ledger.entities == Just []
    then Ok wholeLedger
    else
      case result of
        Ok _ -> Ok wholeLedger
        Error error -> Error error


fromJson :: String -> Result String Ledger
fromJson json = do
  jsonObj <- fromEither $ jsonParser json
  ledger <- fromEither $ decodeJson jsonObj
  pure ledger
    >>= verifyAccounts
    >>= verifyLedgerBalances
    -- TODO: >>= addInitalBalance


fromYaml :: String -> Result String Ledger
fromYaml yaml =
  let
    result = yaml
      # parseYAMLToJson
      # runExcept
      # fromEither
    unverified = case result of
      Error error -> Error
        ( "Could not parse YAML: "
          <> fold (map renderForeignError error)
        )
      Ok json -> fromEither $ decodeJson json
  in
    unverified
      >>= verifyAccounts
      >>= verifyLedgerBalances


showPretty :: Ledger -> String
showPretty = showPrettyAligned ColorNo


showPrettyAligned :: ColorFlag -> Ledger -> String
showPrettyAligned colorFlag (Ledger l) =
  let
    transactionsPretty = map
      (Transaction.showPrettyAligned colorFlag)
      l.transactions
  in ""
    <> "Journal for \"" <> l.owner <> "\"\n"
    <> "=" `power` 80 <> "\n"
    <> fold transactionsPretty


showTransfers :: ColorFlag -> Ledger -> String
showTransfers colorFlag (Ledger l) =
  let
    transactionsPretty = l.transactions
      <#> Transaction.showTransfersWithDate colorFlag
      # fold
  in ""
    <> "Journal for \"" <> l.owner <> "\"\n"
    <> "=" `power` 80 <> "\n"
    <> transactionsPretty


type BalanceMap = Map.Map Account.Id CommodityMap


isBalanceMapZero :: BalanceMap -> Boolean
isBalanceMapZero balanceMap =
  (Map.values balanceMap)
  # all isCommodityMapZero


addTransaction :: BalanceMap -> Transaction -> BalanceMap
addTransaction balanceMap (Transaction {transfers})  =
  foldr (flip addTransfer) balanceMap transfers


addTransfer :: BalanceMap -> Transfer -> BalanceMap
addTransfer balanceMap (Transfer {to, from, amount})  =
  let
    -- toArray = split (Pattern "") to
    -- toDefault = case toArray of
    --   [] -> toArray <> "_default_"
    --   []
    -- fromArray = split (Pattern "") from
    updatedFromAccount = Map.alter
      (\maybeValue -> case maybeValue of
        Nothing ->
          Just ((Map.empty :: CommodityMap) `subtractAmountFromMap` amount)
        Just commodityMap ->
          Just (commodityMap `subtractAmountFromMap` amount)
      )
      from
      balanceMap
  in
    Map.alter
      (\maybeValue -> case maybeValue of
        Nothing ->
          Just ((Map.empty :: CommodityMap) `addAmountToMap` amount)
        Just commodityMap ->
          Just (commodityMap `addAmountToMap` amount)
      )
      to
      updatedFromAccount


subtractTransfer :: BalanceMap -> Transfer -> BalanceMap
subtractTransfer balanceMap transfer  =
  let transferNegated = negateTransfer transfer
  in balanceMap `addTransfer` transferNegated


showBalance :: ColorFlag -> Ledger -> String
showBalance colorFlag (Ledger ledger) =
  let
    balanceMap = foldr (flip addTransaction) Map.empty ledger.transactions
    balancesArray = balanceMap
      # (Map.toUnfoldable :: BalanceMap ->
          Array (Tuple Account.Id CommodityMap))
    accWidthRecs :: Array WidthRecord
    accWidthRecs = balancesArray
      <#> (\(Tuple accId comMap) -> Account.toWidthRecord accId comMap)
    widthRecord :: WidthRecord
    widthRecord = foldr mergeWidthRecords widthRecordZero accWidthRecs
    marginLeft = 2
  in
    balancesArray
      <#> (\(Tuple accId comMap) -> (Account.showPrettyAligned
            colorFlag
            widthRecord { account = widthRecord.account + marginLeft }
            accId
            comMap
          ))
      # fold


-- | Serializes the journal to a command line printable version
-- | (lines of columns).
getEntries :: Ledger -> Maybe (Array (Array String))
getEntries (Ledger {transactions}) = do
  let
    getQunty (Amount quantity _ ) = show $ toNumber quantity
    getCmdty (Amount _ commodity ) = unwrap commodity

    splitTransfer :: Transfer -> Maybe (Array (Array String))
    splitTransfer (Transfer tfer) =
      let
        fromAmnt = Amount.negate tfer.amount
        getFromAndTo date =
          [ [date, tfer.from, getQunty fromAmnt, getCmdty fromAmnt]
          , [date, tfer.to, getQunty tfer.amount, getCmdty tfer.amount]
          ]
      in
        (tfer.utc <#> utcToIsoString) <#> getFromAndTo

  splitted <- do
    transactions
    <#> (\(Transaction tact) -> tact.transfers
      <#> (\(Transfer tfer) -> Transfer (tfer { utc = tfer.utc <|> tact.utc })))
    # concat
    <#> splitTransfer
    # sequence

  pure $ splitted # concat


maybeToArr :: forall a. Maybe a -> Array a
maybeToArr m = case m of
  Just val -> [val]
  Nothing -> []


-- | Serialize the journal to the Ledger format.
entriesToLedger :: Ledger -> String
entriesToLedger (Ledger { transactions }) =
  let
    print :: DateTime -> Maybe String -> Account.Id
      -> Account.Id -> Amount -> String
    print dt maybeNote from to amount =
        let date = dt # utcToIsoDateString
            note = maybe "" identity maybeNote
        in date <> " " <> note <> "\n" <>
           "  " <> to <> "  " <> (Amount.showPretty amount) <> "\n" <>
           "  " <> from <> "\n"

    result = do
        Transaction { utc , note, transfers } <- transactions
        xutc <- maybeToArr utc
        Transfer { to, from, amount } <- transfers
        pure $ print xutc note from to amount

  in result # joinWith "\n"


showEntries :: String -> Ledger -> Maybe String
showEntries separator ledger = do
  entries <- getEntries ledger

  pure $ entries
    # sort
    <#> joinWith separator
    # joinWith "\n"


showEntriesByAccount :: Ledger -> Maybe String
showEntriesByAccount ledger = do
  let
    accountCommodity array =
      fromMaybe "" (array !! 1) <> " " <> fromMaybe "" (array !! 3)
    compareAccComm a b = accountCommodity a `compare` accountCommodity b
    isEqualAccComm a b = accountCommodity a == accountCommodity b
    accCommOfGroup array = "\""
      <> (accountCommodity $ fromMaybe [] (array !! 0))
      <> "\""

  entries <- getEntries ledger

  pure $ entries
      # sortBy compareAccComm
      # groupBy isEqualAccComm
      <#> Array.fromFoldable  -- Convert each NonEmpty to Array
      <#> sort  -- Sort each entry by date
      <#> (\array -> [[accCommOfGroup array]] <> array)
      # intercalate [["\n"]]  -- Add space between account entries
      <#> joinWith " "  -- Join fields for each row
      # joinWith "\n"
