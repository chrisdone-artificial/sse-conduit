{-# LANGUAGE OverloadedStrings #-}

import Test.Hspec
import Data.Conduit
import qualified Data.Conduit.List as CL
import Data.Conduit.SSE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8

-- Helper function to parse a list of ByteStrings into ServerEvents
parseSSE :: [BS.ByteString] -> IO [ServerEvent]
parseSSE chunks = runConduit $ CL.sourceList chunks .| sseParser .| CL.consume

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "sseParser" $ do

    it "parses a simple event with data" $ do
      let input = ["data: hello world\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "hello world" Nothing]

    it "parses an event with type and data" $ do
      let input = ["event: message\n", "data: hello\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent (Just "message") Nothing "hello" Nothing]

    it "parses multi-line data fields" $ do
      let input = ["data: first line\n", "data: second line\n", "data: third line\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "first line\nsecond line\nthird line" Nothing]

    it "parses event with id" $ do
      let input = ["id: 123\n", "data: test\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing (Just "123") "test" Nothing]

    it "parses event with retry" $ do
      let input = ["retry: 5000\n", "data: test\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "test" (Just 5000)]

    it "parses complete event with all fields" $ do
      let input = ["event: update\n", "id: 42\n", "retry: 3000\n", "data: complete event\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent (Just "update") (Just "42") "complete event" (Just 3000)]

    it "parses multiple events in sequence" $ do
      let input = ["data: first\n\n", "data: second\n\n", "data: third\n\n"]
      result <- parseSSE input
      result `shouldBe`
        [ ServerEvent Nothing Nothing "first" Nothing
        , ServerEvent Nothing Nothing "second" Nothing
        , ServerEvent Nothing Nothing "third" Nothing
        ]

    it "ignores comment lines" $ do
      let input = [": this is a comment\n", "data: real data\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "real data" Nothing]

    it "handles fields with leading space after colon" $ do
      let input = ["data:  hello\n\n"]  -- Two spaces after colon
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing " hello" Nothing]

    it "handles fields without space after colon" $ do
      let input = ["data:hello\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "hello" Nothing]

    it "handles empty data field" $ do
      let input = ["data:\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "" Nothing]

    it "handles chunked input across event boundaries" $ do
      let input = ["data: hel", "lo\n\n", "data: wor", "ld\n\n"]
      result <- parseSSE input
      result `shouldBe`
        [ ServerEvent Nothing Nothing "hello" Nothing
        , ServerEvent Nothing Nothing "world" Nothing
        ]

    it "handles chunked input with incomplete lines" $ do
      let input = ["data: test", " message\n", "\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "test message" Nothing]

    it "rejects retry with invalid format" $ do
      let input = ["retry: not-a-number\n", "data: test\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "test" Nothing]

    it "rejects negative retry values" $ do
      let input = ["retry: -100\n", "data: test\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "test" Nothing]

    it "accepts retry with trailing content as invalid" $ do
      let input = ["retry: 100extra\n", "data: test\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "test" Nothing]

    it "rejects id with null character" $ do
      let input = ["id: bad\x00id\n", "data: test\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "test" Nothing]

    it "handles CRLF line endings" $ do
      let input = ["data: windows\r\n\r\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "windows" Nothing]

    it "ignores unknown fields" $ do
      let input = ["unknown: field\n", "data: test\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "test" Nothing]

    it "handles event with only blank line" $ do
      let input = ["\n"]
      result <- parseSSE input
      result `shouldBe` []

    it "handles multiple blank lines between events" $ do
      let input = ["data: first\n\n\n\n", "data: second\n\n"]
      result <- parseSSE input
      result `shouldBe`
        [ ServerEvent Nothing Nothing "first" Nothing
        , ServerEvent Nothing Nothing "second" Nothing
        ]

    it "handles real-world streaming scenario" $ do
      let input =
            [ "retry: 10000\n"
            , ": keepalive comment\n"
            , "event: userJoined\n"
            , "id: msg1\n"
            , "data: {\"user\": \"alice\"}\n"
            , "\n"
            , "event: message\n"
            , "id: msg2\n"
            , "data: {\"from\": \"alice\",\n"
            , "data:  \"text\": \"hello\"}\n"
            , "\n"
            ]
      result <- parseSSE input
      result `shouldBe`
        [ ServerEvent (Just "userJoined") (Just "msg1") "{\"user\": \"alice\"}" (Just 10000)
        , ServerEvent (Just "message") (Just "msg2") "{\"from\": \"alice\",\n \"text\": \"hello\"}" Nothing
        ]

    it "handles tiny chunks simulating slow network" $ do
      let input = map BS8.singleton "data: slow\n\n"
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "slow" Nothing]

    it "does not emit event without data field" $ do
      let input = ["event: test\n", "id: 1\n\n"]
      result <- parseSSE input
      result `shouldBe` []

    it "handles data field with colon in value" $ do
      let input = ["data: http://example.com\n\n"]
      result <- parseSSE input
      result `shouldBe` [ServerEvent Nothing Nothing "http://example.com" Nothing]
