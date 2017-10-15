{-# LANGUAGE TemplateHaskell #-}

module Main where

import           Control.Concurrent                                 (threadDelay)
import           Control.Distributed.Process
import           Control.Distributed.Process.Backend.SimpleLocalnet
import           Control.Distributed.Process.Closure                (mkClosure,
                                                                     remotable)
import           Control.Distributed.Process.Node                   (initRemoteTable)
import           Control.Monad                                      (when)
import           Control.Monad.Random
import           Data.Binary
import qualified Data.Map                                           as M
import           Data.Time
import           System.Console.GetOpt
import           System.Environment                                 (getArgs)
import           Text.Printf
import           Text.Read                                          (readMaybe)

import           ProbabilisticReliableMulticast

data Options = Options {
    oHost             :: !String
  , oPort             :: !String
  , oSendFor          :: !Int
  , oWaitFor          :: !Int
  , oSeed             :: !Int
  , oMaster           :: !Bool
  , oSimLinkFailures  :: !Double
  , oFanout           :: !Int
  , oGossipInterval   :: !Int
  , oQuiescense       :: !Int
  }

startOptions :: Options
startOptions = Options { oHost = "192.168.0.33"
                       , oPort = "9000"
                       , oSendFor = 10
                       , oWaitFor = 5
                       , oSeed    = 42
                       , oMaster  = False
                       , oSimLinkFailures = 0
                       , oFanout  = 3
                       , oGossipInterval = 200000
                       , oQuiescense = 2
                       }

options :: [ OptDescr (Options -> IO Options) ]
options = [
    Option "a" ["fanout"]
      (ReqArg (\arg opt -> return $ opt {oFanout = parseNat "fanout" arg})
       "Peers")
      "Fanout, number of random peers to gossip with"
  , Option "g" ["gossip-interval"]
      (ReqArg (\arg opt -> return $ opt {oGossipInterval = parseNat "gossip-interval" arg})
       "ns")
      "Interval in ns between gossip messages"
  , Option "h" ["host"]
      (ReqArg (\arg opt -> return $ opt {oHost = arg})
       "Host")
      "Host IP address"
  , Option "k" ["send-for"]
      (ReqArg (\arg opt -> return $ opt {oSendFor = parseNat "send-for" arg})
       "Seconds")
      "Send for k seconds"
  , Option "f" ["link-faults"]
      (ReqArg (\arg opt -> return opt {oSimLinkFailures = parsePercent "link-failures" arg})
       "Percent")
      "Percent of of random link failures"
  , Option "l" ["wait-for"]
      (ReqArg (\arg opt -> return opt {oWaitFor = parseNat "wait-for" arg})
       "Seconds")
      "Wait for l seconds"
  , Option "m" ["master"]
      (NoArg (\opt -> return opt {oMaster = True}))
      "start in master mode"
  , Option "p" ["port"]
      (ReqArg (\arg opt -> return $ opt {oPort = arg})
       "Port")
      "Port"
   , Option "q" ["quiescense"]
      (ReqArg (\arg opt -> return $ opt {oSendFor = parseNat "quiescense" arg})
       "quiescense")
      "Number of times to gossip about new messages"
  , Option "s" ["seed"]
      (ReqArg (\arg opt -> return opt {oSeed = parseNat "seed" arg})
       "Seed")
      "Random Seed"
  ]

parseNat :: String -> String -> Int
parseNat n a =
  case readMaybe a of
       Nothing -> error $ n ++ " must be an int."
       Just s  ->
         if s < 0 then error $ n ++ " must be a _positive_ int."
                  else s

parsePercent :: String -> String -> Double
parsePercent n a =
  case readMaybe a of
       Nothing -> error $ n ++ " must be an float."
       Just s  ->
         if s < 0 || s > 100 then error $ n ++ " must be a float between 0 and 100."
                             else s


randomStreamTask :: (Int, Int, Int, Int, Double, Int, Int, Int) -> Process ()
randomStreamTask (sendFor, waitFor, seed, slaveSeed, linkFailures, fanout, gossipInt, quies) = do
  say $ printf ("sendFor %d, waitfor %d seed %d slave seed %d linkFailures %02f " ++
                "fanout %d gossipInt %d quies %d") sendFor waitFor seed slaveSeed linkFailures
                fanout gossipInt quies
  myNid <-getSelfNode
  peers <- filter (/= myNid) <$> expect
  say $ printf "got peers %s, my pid %s" (show peers) (show myNid)
  let rng = mkStdGen seed
  let slaveRng = mkStdGen slaveSeed
      (gossipSeed, slaveRng') = random slaveRng
      (failureSeed, _)        = random slaveRng'

  now <- liftIO getCurrentTime
  let end0 = addUTCTime (fromIntegral sendFor) now
  let end1 = addUTCTime (fromIntegral $ sendFor + waitFor) now
  ctx <- prmInitialize gossipSeed fanout gossipInt quies
  mapM (prmWaitForPeer ctx) peers
  spawnLocal $ prmSimulatedLinkFaults failureSeed ctx (length peers) linkFailures
  say "period0 start"
  period0 rng ctx end0
  say "period0 done"

  -- wait for "some unreceived messages"
  liftIO $ threadDelay $ 1000000 * waitFor
  res <- prmGetMessages ctx
  liftIO $ printf "(%d,\n" $ length res
  liftIO $ mapM_ (\m -> printf "%u,%s,%d,%f\n" (unTs $ pmTimestamp m) (show $ pmiNid $ pmId m)
                       (unSeq $ pmiSeq $ pmId m) (pmPayload m)) res
  liftIO $ printf ")\n"
  return ()

  return ()
  where
    period0 rng ctx end = do
      now <- liftIO getCurrentTime
      unless (now >= end) $ do
        let (v, rng') = random rng
        prmSend ctx v
        prmReceiveTimeout ctx 1000000
        period0 rng' ctx end

remotable ['randomStreamTask]

master :: Options -> Backend -> [NodeId] -> Process ()
master opts backend slaves = do
  liftIO . putStrLn $ "Slaves: " ++ show slaves
  let rng = mkStdGen $ oSeed opts
  pids <- spawnSlave rng slaves []
  liftIO $ printf "pids: %s\n" (show pids)
  mapM_ (`send` slaves) pids
  say "sent nids"
  liftIO $ threadDelay $ (1 + oSendFor opts + oWaitFor opts) * 1000000
  terminateAllSlaves backend
  return ()
  where
    spawnSlave _ [] pids = return pids
    spawnSlave rng (nid:nids) pids = do
      let (slaveSeed, rng') = random rng
      pid <- spawn nid $ $(mkClosure 'randomStreamTask)
                          (oSendFor opts, oWaitFor opts, oSeed opts, slaveSeed :: Int,
                           oSimLinkFailures opts, oFanout opts, oGossipInterval opts,
                           oQuiescense opts)
      spawnSlave rng' nids (pid:pids) 


myRemoteTable :: RemoteTable
myRemoteTable = Main.__remoteTable initRemoteTable


main :: IO ()
main = do
  args <- getArgs
  let (actions, nonOptions, cmdErr) = getOpt RequireOrder options args
  when (cmdErr /= []) $
    ioError (userError (concat cmdErr ++ usageInfo "" options))
  opts <- foldl (>>=) (return startOptions) actions

  let Options { oHost   = host
              , oPort   = port
              , oMaster = isMaster } = opts

  backend <- initializeBackend host port myRemoteTable
  if isMaster
     then startMaster backend (master opts backend)
     else startSlave backend

