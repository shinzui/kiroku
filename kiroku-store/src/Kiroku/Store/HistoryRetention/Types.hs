module Kiroku.Store.HistoryRetention.Types (
    HistoryRetentionLeaseId (..),
    HistoryRetentionLeaseOwner,
    HistoryRetentionLeaseReason,
    HistoryRetentionLeaseDuration,
    HistoryRetentionLeaseRequest (..),
    HistoryRetentionLeaseHandle (..),
    HistoryRetentionLeaseState (..),
    HistoryRetentionLease (..),
    HistoryRetentionRenewalError (..),
    HistoryRetentionReleaseResult (..),
    HistoryRetentionConflict (..),
    HistoryRetentionInventoryLimit,
    HistoryRetentionInventoryQuery (..),
    HistoryRetentionPruneResult (..),
    HistoryRetentionRequestError (..),
    HistoryRetentionInventoryError (..),
    StreamHistoryUnavailable (..),
    mkHistoryRetentionLeaseOwner,
    mkHistoryRetentionLeaseReason,
    mkHistoryRetentionLeaseDuration,
    mkHistoryRetentionInventoryLimit,
    historyRetentionLeaseOwnerText,
    historyRetentionLeaseReasonText,
    historyRetentionLeaseDurationValue,
    historyRetentionInventoryLimitValue,
    maxHistoryRetentionLeaseDuration,
) where

import Data.ByteString qualified as ByteString
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (DiffTime, UTCTime, secondsToDiffTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Kiroku.Store.Types (GlobalPosition, StreamName)

-- | Database-generated identity of one durable retention lease.
newtype HistoryRetentionLeaseId = HistoryRetentionLeaseId UUID
    deriving stock (Eq, Ord, Show, Generic)

-- | Validated operational owner label (1 through 512 UTF-8 bytes).
newtype HistoryRetentionLeaseOwner = HistoryRetentionLeaseOwner Text
    deriving stock (Eq, Ord, Show, Generic)

-- | Validated human-readable reason (1 through 2,048 UTF-8 bytes).
newtype HistoryRetentionLeaseReason = HistoryRetentionLeaseReason Text
    deriving stock (Eq, Ord, Show, Generic)

-- | Requested remaining lifetime, from one second through one hour.
newtype HistoryRetentionLeaseDuration = HistoryRetentionLeaseDuration DiffTime
    deriving stock (Eq, Ord, Show, Generic)

data HistoryRetentionLeaseRequest = HistoryRetentionLeaseRequest
    { owner :: !HistoryRetentionLeaseOwner
    , reason :: !HistoryRetentionLeaseReason
    , duration :: !HistoryRetentionLeaseDuration
    }
    deriving stock (Eq, Show, Generic)

data HistoryRetentionLeaseHandle = HistoryRetentionLeaseHandle
    { leaseId :: !HistoryRetentionLeaseId
    , owner :: !HistoryRetentionLeaseOwner
    }
    deriving stock (Eq, Show, Generic)

data HistoryRetentionLeaseState
    = HistoryRetentionLeaseActive
    | HistoryRetentionLeaseExpired
    | HistoryRetentionLeaseReleased
    deriving stock (Eq, Ord, Show, Generic)

data HistoryRetentionLease = HistoryRetentionLease
    { leaseId :: !HistoryRetentionLeaseId
    , owner :: !HistoryRetentionLeaseOwner
    , reason :: !HistoryRetentionLeaseReason
    , protectedThrough :: !GlobalPosition
    , createdAt :: !UTCTime
    , renewedAt :: !UTCTime
    , expiresAt :: !UTCTime
    , releasedAt :: !(Maybe UTCTime)
    , state :: !HistoryRetentionLeaseState
    }
    deriving stock (Eq, Show, Generic)

data HistoryRetentionRenewalError
    = HistoryRetentionRenewalUnknown
    | HistoryRetentionRenewalOwnerMismatch
    | HistoryRetentionRenewalExpired
    | HistoryRetentionRenewalReleased
    deriving stock (Eq, Show, Generic)

data HistoryRetentionReleaseResult
    = HistoryRetentionReleased !HistoryRetentionLease
    | HistoryRetentionAlreadyReleased !HistoryRetentionLease
    | HistoryRetentionReleaseExpired !HistoryRetentionLease
    | HistoryRetentionReleaseUnknown
    | HistoryRetentionReleaseOwnerMismatch
    deriving stock (Eq, Show, Generic)

data HistoryRetentionConflict = HistoryRetentionConflict
    { activeLeaseCount :: !Int64
    , earliestExpiry :: !UTCTime
    }
    deriving stock (Eq, Show, Generic)

-- | Validated maximum number of inventory rows (1 through 1,000).
newtype HistoryRetentionInventoryLimit = HistoryRetentionInventoryLimit Int32
    deriving stock (Eq, Ord, Show, Generic)

data HistoryRetentionInventoryQuery = HistoryRetentionInventoryQuery
    { limit :: !HistoryRetentionInventoryLimit
    }
    deriving stock (Eq, Show, Generic)

data HistoryRetentionPruneResult = HistoryRetentionPruneResult
    { expiredPruned :: !Int64
    , releasedPruned :: !Int64
    }
    deriving stock (Eq, Show, Generic)

data HistoryRetentionRequestError
    = HistoryRetentionLeaseOwnerEmpty
    | HistoryRetentionLeaseOwnerTooLong !Int
    | HistoryRetentionLeaseReasonEmpty
    | HistoryRetentionLeaseReasonTooLong !Int
    | HistoryRetentionLeaseDurationOutOfRange !DiffTime
    deriving stock (Eq, Show, Generic)

data HistoryRetentionInventoryError
    = HistoryRetentionInventoryLimitOutOfRange !Int32
    deriving stock (Eq, Show, Generic)

data StreamHistoryUnavailable
    = StreamHistoryNotFound !StreamName
    | StreamHistoryReserved !StreamName
    deriving stock (Eq, Show, Generic)

mkHistoryRetentionLeaseOwner :: Text -> Either HistoryRetentionRequestError HistoryRetentionLeaseOwner
mkHistoryRetentionLeaseOwner value
    | bytes == 0 = Left HistoryRetentionLeaseOwnerEmpty
    | bytes > 512 = Left (HistoryRetentionLeaseOwnerTooLong bytes)
    | otherwise = Right (HistoryRetentionLeaseOwner value)
  where
    bytes = ByteString.length (Text.encodeUtf8 value)

mkHistoryRetentionLeaseReason :: Text -> Either HistoryRetentionRequestError HistoryRetentionLeaseReason
mkHistoryRetentionLeaseReason value
    | bytes == 0 = Left HistoryRetentionLeaseReasonEmpty
    | bytes > 2048 = Left (HistoryRetentionLeaseReasonTooLong bytes)
    | otherwise = Right (HistoryRetentionLeaseReason value)
  where
    bytes = ByteString.length (Text.encodeUtf8 value)

mkHistoryRetentionLeaseDuration :: DiffTime -> Either HistoryRetentionRequestError HistoryRetentionLeaseDuration
mkHistoryRetentionLeaseDuration value
    | value < secondsToDiffTime 1 = Left (HistoryRetentionLeaseDurationOutOfRange value)
    | value > maxHistoryRetentionLeaseDuration = Left (HistoryRetentionLeaseDurationOutOfRange value)
    | otherwise = Right (HistoryRetentionLeaseDuration value)

mkHistoryRetentionInventoryLimit :: Int32 -> Either HistoryRetentionInventoryError HistoryRetentionInventoryLimit
mkHistoryRetentionInventoryLimit value
    | value < 1 || value > 1000 = Left (HistoryRetentionInventoryLimitOutOfRange value)
    | otherwise = Right (HistoryRetentionInventoryLimit value)

historyRetentionLeaseOwnerText :: HistoryRetentionLeaseOwner -> Text
historyRetentionLeaseOwnerText (HistoryRetentionLeaseOwner value) = value

historyRetentionLeaseReasonText :: HistoryRetentionLeaseReason -> Text
historyRetentionLeaseReasonText (HistoryRetentionLeaseReason value) = value

historyRetentionLeaseDurationValue :: HistoryRetentionLeaseDuration -> DiffTime
historyRetentionLeaseDurationValue (HistoryRetentionLeaseDuration value) = value

historyRetentionInventoryLimitValue :: HistoryRetentionInventoryLimit -> Int32
historyRetentionInventoryLimitValue (HistoryRetentionInventoryLimit value) = value

maxHistoryRetentionLeaseDuration :: DiffTime
maxHistoryRetentionLeaseDuration = secondsToDiffTime 3600
