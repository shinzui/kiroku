module Kiroku.Store.Types (
    StreamUuid (..),
    StreamId (..),
    EventId (..),
    EventType (..),
    StreamVersion (..),
    GlobalPosition (..),
    ExpectedVersion (..),
    EventData (..),
    RecordedEvent (..),
    StreamInfo (..),
    AppendResult (..),
) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

-- Stream identification
newtype StreamUuid = StreamUuid Text
    deriving stock (Eq, Ord, Show, Generic)

newtype StreamId = StreamId Int64
    deriving stock (Eq, Ord, Show, Generic)

-- Event identification
newtype EventId = EventId UUID
    deriving stock (Eq, Ord, Show, Generic)

newtype EventType = EventType Text
    deriving stock (Eq, Ord, Show, Generic)

-- Positions
newtype StreamVersion = StreamVersion Int64
    deriving stock (Eq, Ord, Show, Generic)

newtype GlobalPosition = GlobalPosition Int64
    deriving stock (Eq, Ord, Show, Generic)

-- | Version expectations for appends.
data ExpectedVersion
    = -- | Stream must not exist yet
      NoStream
    | -- | Must exist, any version
      StreamExists
    | -- | Must match exactly
      ExactVersion !StreamVersion
    | -- | Create or append, don't care
      AnyVersion
    deriving stock (Eq, Show, Generic)

-- | What the caller provides when appending events.
data EventData = EventData
    { eventId :: !(Maybe EventId)
    -- ^ Nothing = pre-generated UUIDv7 by store; Just = caller-supplied (for idempotent retries)
    , eventType :: !EventType
    , payload :: !Value
    -- ^ JSONB payload
    , metadata :: !(Maybe Value)
    -- ^ JSONB metadata
    , causationId :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    }
    deriving stock (Show, Generic)

-- | Stream metadata returned by getStream.
data StreamInfo = StreamInfo
    { id :: !StreamId
    , uuid :: !StreamUuid
    , version :: !StreamVersion
    , createdAt :: !UTCTime
    , deletedAt :: !(Maybe UTCTime)
    }
    deriving stock (Eq, Show, Generic)

-- | What comes back from reading events.
data RecordedEvent = RecordedEvent
    { eventId :: !EventId
    , eventType :: !EventType
    , streamVersion :: !StreamVersion
    -- ^ Version in the stream being read
    , globalPosition :: !GlobalPosition
    , originalStreamId :: !StreamId
    -- ^ Stream the event was originally appended to
    , originalVersion :: !StreamVersion
    -- ^ Version in the original stream
    , payload :: !Value
    , metadata :: !(Maybe Value)
    , causationId :: !(Maybe UUID)
    , correlationId :: !(Maybe UUID)
    , createdAt :: !UTCTime
    }
    deriving stock (Eq, Show, Generic)

-- | Result of a successful append.
data AppendResult = AppendResult
    { streamId :: !StreamId
    , streamVersion :: !StreamVersion
    , globalPosition :: !GlobalPosition
    }
    deriving stock (Eq, Show, Generic)
