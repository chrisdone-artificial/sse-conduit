{-# LANGUAGE OverloadedStrings #-}

module Data.Conduit.SSE
    ( ServerEvent(..)
    , sseParser
    ) where

import Data.Conduit
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8

-- | Represents a parsed Server-Sent Event
data ServerEvent = ServerEvent
    { eventType :: Maybe ByteString  -- ^ Event type (from "event:" field)
    , eventId   :: Maybe ByteString  -- ^ Event ID (from "id:" field)
    , eventData :: ByteString        -- ^ Event data (from "data:" fields, joined with newlines)
    , eventRetry :: Maybe Int        -- ^ Retry time in milliseconds (from "retry:" field)
    } deriving (Show, Eq)

-- | Internal state for SSE parsing
data SSEState = SSEState
    { stateLines :: [ByteString]     -- ^ Accumulated lines
    , stateBuffer :: ByteString      -- ^ Incomplete line buffer
    , stateEvent :: Maybe ByteString
    , stateId :: Maybe ByteString
    , stateData :: [ByteString]
    , stateRetry :: Maybe Int
    }

initialState :: SSEState
initialState = SSEState [] BS.empty Nothing Nothing [] Nothing

-- | Conduit that parses a ByteString stream into ServerEvents
sseParser :: Monad m => ConduitT ByteString ServerEvent m ()
sseParser = go initialState
  where
    go state = await >>= maybe (finish state) (process state)

    process state chunk =
        let (lines', remainder) = extractLines (stateBuffer state <> chunk)
            newState = foldl processLine state lines'
        in do
            case stateLines newState of
                [] -> go newState { stateBuffer = remainder }
                _  -> do
                    let events = buildEvents newState
                    mapM_ yield events
                    go initialState { stateBuffer = remainder }

    finish state =
        case stateBuffer state of
            buf | BS.null buf -> return ()
                | otherwise -> do
                    let finalState = processLine state buf
                    let events = buildEvents finalState
                    mapM_ yield events

-- | Extract complete lines from a ByteString, returning lines and remainder
extractLines :: ByteString -> ([ByteString], ByteString)
extractLines bs = go [] bs
  where
    go acc remainder =
        case BS8.elemIndex '\n' remainder of
            Nothing -> (reverse acc, remainder)
            Just idx ->
                let (line, rest) = BS.splitAt (idx + 1) remainder
                    cleanLine = BS8.takeWhile (/= '\r') (BS.init line)
                in go (cleanLine : acc) rest

-- | Process a single line and update the SSE state
processLine :: SSEState -> ByteString -> SSEState
processLine state line
    | BS.null line = state { stateLines = line : stateLines state }
    | BS8.head line == ':' = state  -- Comment, ignore
    | otherwise =
        case BS8.break (== ':') line of
            (field, value) ->
                let cleanValue = BS.drop 1 value  -- Drop the ':'
                    trimValue = if BS.length cleanValue > 0 && BS8.head cleanValue == ' '
                                then BS.tail cleanValue
                                else cleanValue
                in updateField state field trimValue

-- | Update SSE state based on field name and value
updateField :: SSEState -> ByteString -> ByteString -> SSEState
updateField state field value
    | field == "event" = state { stateEvent = Just value }
    | field == "data" = state { stateData = value : stateData state }
    | field == "id" = state { stateId = if BS8.any (== '\0') value
                                        then stateId state
                                        else Just value }
    | field == "retry" = state { stateRetry = parseRetry value }
    | otherwise = state

-- | Parse retry value as integer
parseRetry :: ByteString -> Maybe Int
parseRetry bs =
    case BS8.readInt bs of
        Just (n, remainder) | BS.null remainder && n >= 0 -> Just n
        _ -> Nothing

-- | Build ServerEvents from accumulated state
buildEvents :: SSEState -> [ServerEvent]
buildEvents state
    | null (stateData state) = []
    | otherwise =
        let eventData' = BS.intercalate "\n" (reverse $ stateData state)
            event = ServerEvent
                { eventType = stateEvent state
                , eventId = stateId state
                , eventData = eventData'
                , eventRetry = stateRetry state
                }
        in [event]
