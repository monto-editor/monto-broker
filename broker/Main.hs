{-# LANGUAGE OverloadedStrings,ScopedTypeVariables #-}
module Main where

import           System.ZMQ4 (Pair,Context,Socket,Pub)
import qualified System.ZMQ4 as Z hiding (message,source)
import           System.Posix.Signals (installHandler, Handler(Catch), sigINT, sigTERM)

import           Control.Concurrent
import           Control.Monad

import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import           Data.Foldable (for_)
import qualified Data.List as List
import           Data.Map (Map)
import qualified Data.Map as M
import           Data.Maybe
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as TextEnc
import qualified Data.Vector as V

import           Monto.Broker (Broker,Response)
import qualified Monto.Broker as B
--import           Monto.ConfigurationMessage (ConfigurationMessage)
--import qualified Monto.ConfigurationMessage as ConfigMsg
import qualified Monto.DeregisterService as D
import           Monto.DiscoverRequest (ServiceDiscover)
import qualified Monto.DiscoverRequest as DiscoverReq
import           Monto.DiscoverResponse (DiscoverResponse)
import qualified Monto.DiscoverResponse as DiscoverResp
import           Monto.ProductMessage (ProductMessage)
import qualified Monto.ProductMessage as P
import qualified Monto.RegisterServiceRequest as RQ
import qualified Monto.RegisterServiceResponse as RS
import           Monto.Types
import           Monto.VersionMessage (VersionMessage)
import qualified Monto.VersionMessage as V

import           Options.Applicative

import           Text.Printf

type Addr = String
type SocketPool = Map Port (Socket Pair)
type AppState = (Broker, SocketPool)

data Options = Options
  { debug         :: Bool
  , sink          :: Addr
  , source        :: Addr
  , registration  :: Addr
  , discovery     :: Addr
  , config        :: Addr
  , fromPort      :: Port
  , toPort        :: Port
  }

options :: Parser Options
options = Options
  <$> switch      (short 'd' <> long "debug"        <> help "print messages that are transmitted over the broker")
  <*> strOption   (short 'k' <> long "sink"         <> help "address of the sink")
  <*> strOption   (short 'c' <> long "source"       <> help "address of the source")
  <*> strOption   (short 'r' <> long "registration" <> help "address for service registration")
  <*> strOption   (short 'i' <> long "discovery"    <> help "address for service discovery")
  <*> strOption   (short 'o' <> long "config"       <> help "address for service configurations")
  <*> option auto (short 'f' <> long "servicesFrom" <> help "port from which on services can connect")
  <*> option auto (short 't' <> long "servicesTo"   <> help "port to which services can connect")

main :: IO ()
main = do
  opts <- execParser $ info (helper <*> options)
    ( fullDesc
    <> progDesc "Monto Broker"
    )
  Z.withContext $ \ctx ->
    Z.withSocket ctx Z.Pub $ \snk -> do
      Z.bind snk $ sink opts
      putStrLn $ unwords ["publish all products to sink on address", sink opts]
      run opts ctx snk

run :: Options -> Context -> Socket Pub -> IO ()
run opts ctx snk = do
  interrupted <- newEmptyMVar
  let stopExcecution = putMVar interrupted Interrupted
  _ <- installHandler sigINT  (Catch stopExcecution) Nothing
  _ <- installHandler sigTERM (Catch stopExcecution) Nothing

  let broker = B.empty (fromPort opts) (toPort opts)
  appstate <- newMVar (broker, M.empty)
  sourceThread <- runSourceThread opts ctx appstate
  registerThread <- runRegisterThread opts ctx appstate
  discoverThread <- runDiscoverThread opts ctx appstate
  threads <- forM (B.portPool broker) $ runServiceThread opts ctx snk appstate

  _ <- readMVar interrupted
  forM_ threads killThread
  killThread discoverThread
  killThread registerThread
  killThread sourceThread

runSourceThread :: Options -> Context -> MVar AppState -> IO ThreadId
runSourceThread opts ctx appstate = forkIO $
  Z.withSocket ctx Z.Sub $ \src -> do
    Z.bind src $ source opts
    Z.subscribe src ""
    putStrLn $ unwords ["listen on address", source opts, "for versions"]
    forever $ do
      rawMsg <- Z.receive src
      case A.decodeStrict rawMsg of
        Just msg -> do
          when (debug opts) $ putStrLn $ unwords ["version", show (V.source msg),"->", "broker"]
          modifyMVar_ appstate $ onVersionMessage opts msg
        Nothing -> putStrLn "message is not a version message"

runRegisterThread :: Options -> Context -> MVar AppState -> IO ThreadId
runRegisterThread opts ctx appstate = forkIO $
  Z.withSocket ctx Z.Rep $ \socket -> do
    Z.bind socket (registration opts)
    putStrLn $ unwords ["listen on address", registration opts, "for registrations"]
    forever $ do
      rawMsg <- Z.receive socket
      case (A.eitherDecodeStrict rawMsg, A.eitherDecodeStrict rawMsg) of
        (Right msg, _) -> modifyMVar_ appstate $ onRegisterMessage msg socket
        (_, Right msg) -> modifyMVar_ appstate $ onDeregisterMessage msg socket
        (Left r, Left d) -> do
          printf "Couldn't parse message: %s\n%s\n%s\n" (BS.unpack rawMsg) r d
          sendRegisterServiceResponse socket "failed: service did not register correctly" Nothing

runDiscoverThread :: Options -> Context -> MVar AppState -> IO ThreadId
runDiscoverThread opts ctx appstate = forkIO $
  Z.withSocket ctx Z.Rep $ \discSocket -> do
    Z.bind discSocket (discovery opts)
    putStrLn $ unwords ["listen on address", discovery opts, "for discover requests"]
    forever $ do
      rawMsg <- Z.receive discSocket
      case A.decodeStrict rawMsg of
        Just msg -> do
          printf "discover request: %s\n" (show msg)
          (broker, _) <- readMVar appstate
          let services = findServices (DiscoverReq.discoverServices msg) broker
          printf "discover response: %s\n" (show services)
          Z.send discSocket [] $ convertBslToBs $ A.encode services
        Nothing -> printf "couldn't parse discover request: %s\n" $ BS.unpack rawMsg

runServiceThread :: Options -> Context -> Socket Pub -> MVar AppState -> Port -> IO ThreadId
runServiceThread opts ctx snk appstate port@(Port p) = forkIO $
  Z.withSocket ctx Z.Pair $ \sckt -> do
    Z.bind sckt ("tcp://*:" ++ show p)
    printf "listen on address tcp://*:%d for service\n" p
    modifyMVar_ appstate $ \(broker, socketPool) -> return (broker, M.insert port sckt socketPool)
    forever $ do
      rawMsg <- Z.receive sckt
      (broker', _) <- readMVar appstate
      let serviceID = getServiceIdByPort port broker'
      let msg = A.decodeStrict rawMsg
      for_ msg $ \msg' -> do
        Z.send snk [Z.SendMore] $
         BS.unwords $ TextEnc.encodeUtf8 <$>
           [ toText $ P.source msg'
           , toText $ P.product msg'
           , toText $ P.language msg'
           , toText serviceID
           ]
        Z.send snk [] rawMsg
        when (debug opts) $ T.putStrLn $ T.unwords [toText serviceID, toText $ P.source msg', "->", "broker"]
        modifyMVar_ appstate $ onProductMessage opts msg'

findServices :: [ServiceDiscover] -> Broker -> [DiscoverResponse]
findServices discoverList b =
  map serviceToDiscoverResponse $ filterServices $ M.elems $ B.services b
  where
    serviceToDiscoverResponse (B.Service serviceID label description language products _ configuration) =
      DiscoverResp.DiscoverResponse serviceID label description language products configuration

    filterServices
        | null discoverList = id
        | otherwise         = filter $ \(B.Service serviceID' _ _ language' products' _ _) ->
        flip any discoverList $ \(DiscoverReq.ServiceDiscover serviceID'' language'' product'') ->
          maybe True (== serviceID') serviceID''
          && maybe True (== language') language''
          && maybe True (`V.elem` products') product''

getServiceIdByPort :: Port -> Broker -> ServiceID
getServiceIdByPort port broker =
  fromJust $ M.lookup port $ B.serviceOnPort broker

sendRegisterServiceResponse :: Z.Sender a => Socket a -> T.Text -> Maybe Port -> IO ()
sendRegisterServiceResponse socket text port =
  Z.send socket [] $ convertBslToBs $ A.encode $ RS.RegisterServiceResponse text port

onRegisterMessage :: Z.Sender a => RQ.RegisterServiceRequest -> Socket a -> AppState -> IO AppState
onRegisterMessage register regSocket (broker, socketPool) = do
  let serviceID = RQ.serviceID register
  if List.null $ B.portPool broker
  then do
    T.putStrLn $ T.unwords ["register", toText serviceID, "failed: no free ports"]
    sendRegisterServiceResponse regSocket "failed: no free ports" Nothing
    return (broker, socketPool)
  else
    if M.member serviceID (B.services broker)
    then do
      T.putStrLn $ T.unwords ["register", toText serviceID, "failed: service id already exists"]
      sendRegisterServiceResponse regSocket "failed: service id exists" Nothing
      return (broker, socketPool)
    else do
      T.putStrLn $ T.unwords ["register", toText serviceID, "->", "broker"]
      let broker' = B.registerService register broker
      case M.lookup serviceID (B.services broker') of
        Just service ->
          sendRegisterServiceResponse regSocket "ok" $ Just $ B.port service
        Nothing -> do
          T.putStrLn $ T.unwords ["register", toText serviceID, "failed: service did not register correctly"]
          sendRegisterServiceResponse regSocket "failed: service did not register correctly" Nothing
      return (broker', socketPool)

onDeregisterMessage :: Z.Sender a => D.DeregisterService -> Socket a -> AppState -> IO AppState
onDeregisterMessage deregMsg socket (broker, socketPool)= do
  T.putStrLn $ T.unwords ["deregister", toText (D.deregisterServiceID deregMsg), "->", "broker"]
  Z.send socket [] ""
  case M.lookup (D.deregisterServiceID deregMsg) $ B.services broker of
    Just _ -> do
      let broker' = B.deregisterService (D.deregisterServiceID deregMsg) broker
      return (broker', socketPool)
    Nothing -> return (broker, socketPool)

onVersionMessage :: Options -> VersionMessage -> AppState -> IO AppState
{-# INLINE onVersionMessage #-}
onVersionMessage = onMessage B.newVersion

onProductMessage :: Options -> ProductMessage -> AppState -> IO AppState
{-# INLINE onProductMessage #-}
onProductMessage = onMessage B.newProduct

onMessage :: (message -> Broker -> ([Response],Broker)) -> Options -> message -> AppState -> IO AppState
{-# INLINE onMessage #-}
onMessage handler opts msg (broker, socketpool) = do
  let (responses,broker') = handler msg broker
  sendResponses opts (broker, socketpool) responses
  return (broker', socketpool)

sendResponses :: Options -> AppState -> [Response] -> IO ()
{-# INLINE sendResponses #-}
sendResponses opts appstate = mapM_ (sendResponse opts appstate)

sendResponse :: Options -> AppState -> Response -> IO ()
{-# INLINE sendResponse #-}
sendResponse opts (_, socketpool) (B.Response _ service reqs) = do
  let response = A.encode $ A.toJSON $ map toJSON reqs
  Z.send' (socketpool M.! B.port service) [] response
  when (debug opts) $ T.putStrLn $ T.unwords ["broker", showReqs , "->", T.pack $ show service]
  where
    toJSON req = case req of
      B.VersionMessage vers -> A.toJSON vers
      B.ProductMessage prod -> A.toJSON prod
    showReqs :: T.Text
    showReqs = T.unwords $ concat $ forM reqs $ \req ->
      case req of
        B.VersionMessage ver  -> ["version", toText (V.source ver)]
        B.ProductMessage prod -> [toText (P.product prod), "/", toText (P.language prod)]

convertBslToBs :: BSL.ByteString -> BS.ByteString
convertBslToBs msg =
  BS.concat $ BSL.toChunks msg

data Interrupted = Interrupted
  deriving (Eq,Show)
