{-# LANGUAGE OverloadedStrings, RecordWildCards #-}

module Aws.S3.Query
where

import           Aws.Credentials
import           Aws.Http
import           Aws.Query
import           Aws.S3.Info
import           Aws.Signature
import           Aws.Util
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Time
import qualified Blaze.ByteString.Builder       as Blaze
import qualified Blaze.ByteString.Builder.Char8 as Blaze8
import qualified Data.ByteString                as B
import qualified Data.ByteString.Lazy           as L
import qualified Network.HTTP.Types             as HTTP

data S3Query
    = S3Query {
        s3QBucket :: Maybe B.ByteString
      , s3QSubresources :: HTTP.Query
      , s3QQuery :: HTTP.Query
      }
    deriving (Show)

s3SignQuery :: S3Query -> S3Info -> SignatureData -> SignedQuery
s3SignQuery S3Query{..} S3Info{..} SignatureData{..}
    = SignedQuery {
        sqMethod = method
      , sqProtocol = s3Protocol
      , sqHost = endpointHost s3Endpoint
      , sqPort = s3Port
      , sqPath = path
      , sqQuery = sortedSubresources ++ s3QQuery ++ authQuery
      , sqDate = Just signatureTime
      , sqAuthorization = authorization
      , sqContentType = contentType
      , sqContentMd5 = contentMd5
      , sqBody = L.empty
      , sqStringToSign = stringToSign
      }
    where
      method = Get
      contentMd5 = Nothing
      contentType = Nothing
      path = mconcat . catMaybes $ [Just "/", s3QBucket]
      sortedSubresources = sort s3QSubresources
      canonicalizedResource = Blaze.copyByteString "/" `mappend`
                              maybe mempty Blaze.copyByteString s3QBucket `mappend`
                              HTTP.renderQueryBuilder True sortedSubresources
      ti = case (s3UseUri, signatureTimeInfo) of
             (False, ti') -> ti'
             (True, AbsoluteTimestamp time) -> AbsoluteExpires $ s3DefaultExpiry `addUTCTime` time
             (True, AbsoluteExpires time) -> AbsoluteExpires time
      sig = signature signatureCredentials HmacSHA1 stringToSign
      stringToSign = Blaze.toByteString . mconcat . intersperse (Blaze8.fromChar '\n') . concat  $
                       [[Blaze.copyByteString $ httpMethod method]
                       , [maybe mempty Blaze.copyByteString contentMd5]
                       , [maybe mempty Blaze.copyByteString contentType]
                       , [Blaze.copyByteString $ case ti of
                                                   AbsoluteTimestamp time -> fmtRfc822Time time
                                                   AbsoluteExpires time -> fmtTimeEpochSeconds time]
                       , [] -- canonicalized AMZ headers
                       , [canonicalizedResource]
                       ]
      (authorization, authQuery) = case ti of
                                 AbsoluteTimestamp _ -> (Just $ B.concat ["AWS ", accessKeyID signatureCredentials, ":", sig], [])
                                 AbsoluteExpires time -> (Nothing, HTTP.simpleQueryToQuery $ makeAuthQuery time)
      makeAuthQuery time
          = [("Expires", fmtTimeEpochSeconds time)
            , ("AWSAccessKeyId", accessKeyID signatureCredentials)
            , ("SignatureMethod", "HmacSHA256")
            , ("Signature", sig)]
