-- | A partial implementation of Jun Luo's, Patrick Th's and Eugster Jean-pierre Hubaux's 
-- | Probabilistic Reliable Multicast.
-- | Joining (or rejoining) the ad hoc network is not implemented.

{-# LANGUAGE BangPatterns  #-}
{-# LANGUAGE DeriveGeneric #-}

module ProbabilisticReliableMulticast
  ( PrmCtx(..)
  , PrmMessageId (..)
  , PrmMessage (..)
  , PrmSequenceNumber (..)
  , PrmTimestamp (..)

  , prmInitialize
  , prmGetMessages
  , prmReceiveTimeout
  , prmSend
  , prmSimulatedLinkFaults
  , prmWaitForPeer
  )
  where

import           Control.Concurrent                                 (threadDelay)
import           Control.Concurrent.MVar
import           Control.DeepSeq
import           Control.Distributed.Process
import           Control.Distributed.Process.Backend.SimpleLocalnet
import           Control.Distributed.Process.Closure                (mkClosure,
                                                                     remotable)
import           Control.Distributed.Process.Node                   (initRemoteTable)
import           Control.Monad                                      (forever,
                                                                     when)
import           Control.Monad.Random
import           Data.Binary
import           Data.ByteString                                    (ByteString)
import qualified Data.ByteString.Char8                              as Bs
import qualified Data.List                                          as L
import qualified Data.Map.Strict                                    as M
import           Data.Maybe
import qualified Data.Set                                           as S
import           Data.Time
import           Data.Time.Clock
import           Data.Typeable
import           Data.Word
import           GHC.Generics                                       (Generic)
import           Network.Transport                                  (EndPointAddress (..))
import           Text.Printf

import           Grabble

-- |Strict version of say.
say' :: String -> Process ()
say' str = say $ force str

type PrmBufferOld = M.Map PrmMessageId (Maybe PrmMessage)
type PrmBufferNew = (M.Map PrmMessage Int)

data PrmCtx = PrmCtx {
    pcClock          :: !PrmTimestamp      -- ^ Lamport Timestamp
  , pcSeq            :: !PrmSequenceNumber -- ^ Last sequence number
  , pcBufferNew      :: !PrmBufferNew      -- ^ Cache of recent 'PrmMessage'.
  , pcBufferOld      :: !PrmBufferOld      -- ^ Received and "known" missing 'PrmMessage'.
  , pcActiveView     :: ![(NodeId,ProcessId)] -- ^ List of active peers.
  , pcPassiveView    :: ![NodeId]          -- ^ List of unreachable peers.
  , pcFanout         :: !Int               -- ^ Number of Peers to send gossip to.
  , pcGossipInterval :: !Int               -- ^ Time to sleep between gossiping in ns.
  , pcQuiescense     :: !Int               -- ^ Number of times to gossip about a 'PrmMessage'.
} deriving (Generic)

instance NFData PrmCtx

instance Show PrmCtx where
  show ctx = printf "%s,%s,%s,%s,%s,%d,%d,%d" (show $ pcClock ctx) (show $ pcSeq ctx) (show $ pcBufferNew ctx) (show $ pcBufferOld ctx) (show $ pcPassiveView ctx) (pcFanout ctx) (pcGossipInterval ctx) (pcQuiescense ctx)

-- | Sequence number for 'PrmMessageId' in 'PrmMessage'. Incremented by one for every
-- | message sent.
newtype PrmSequenceNumber = PrmSequenceNumber {unSeq :: Word64}
                            deriving (Eq, Show, Ord, Typeable, Generic)
instance NFData PrmSequenceNumber
instance Binary PrmSequenceNumber

prmSeqInc :: PrmSequenceNumber -> PrmSequenceNumber
prmSeqInc sq = PrmSequenceNumber $ 1 + unSeq sq

-- | Lamport Timestamp
newtype PrmTimestamp = PrmTimestamp {unTs :: Word64}
                              deriving (Eq, Show, Ord, Typeable, Generic)

prmTsInc :: PrmTimestamp -> PrmTimestamp
prmTsInc ts = PrmTimestamp $ 1 + unTs ts


instance NFData PrmTimestamp
instance Binary PrmTimestamp


-- | A 'PrmMessage' is uniquely identified by source 'EndPointAddress' and 'PrmSequenceNumber'.
data PrmMessageId = PrmMessageId {
    pmiNid :: !EndPointAddress   -- ^ Source
  , pmiSeq :: !PrmSequenceNumber -- ^ Sequence Number
} deriving (Eq, Typeable, Ord, Generic)

-- | Create a 'PrmMessageId' using a fresh copy of the EndPointAddress.
-- | XXX This shouldn't be needed but I suspect that distributed-process or the
-- | bytestring library is using unsafePerformIO on EndPointAddresses which cause my
-- | application to deadlock when evaluating EndPointAddresses.
prmMessageId :: EndPointAddress -> PrmSequenceNumber -> PrmMessageId
prmMessageId ep sq =
  let ep' = EndPointAddress $ Bs.copy $ endPointAddressToByteString ep in
  force $ PrmMessageId ep' sq

instance Show PrmMessageId where
  show i = printf "%s %ld" (show $ pmiNid i) (unSeq $ pmiSeq i)

instance NFData PrmMessageId

instance Binary PrmMessageId

-- | A message broadcasted to all active peers.
data PrmMessage = PrmMessage {
    pmId        :: !PrmMessageId -- ^ Message Id.
  , pmTimestamp :: !PrmTimestamp -- ^ Timestamp for ordering
  , pmPayload   :: !Double       -- ^ Payload.
} deriving (Typeable, Generic)

-- | Duplicate a 'PrmMessage'.
prmMessageDuplicate :: PrmMessage -> PrmMessage
prmMessageDuplicate msg =
  force $ msg { pmId = prmMessageId (pmiNid $ pmId msg) (pmiSeq $ pmId msg) }

instance NFData PrmMessage

instance Show PrmMessage where
  show msg = printf "PrMessage %s %d %f"  (show $ pmId msg) (unTs $ pmTimestamp msg) (pmPayload msg)

instance Binary PrmMessage

instance Eq PrmMessage where
  a == b = pmId a == pmId b


-- | PrmMessages are ordered based on 'PrmTimestamp' first, ties are decided
-- | by comparing source 'EndPointAddress'.
instance Ord PrmMessage where
  compare a b = if pmTimestamp a == pmTimestamp b
                   then compare (pmiNid $ pmId a) (pmiNid $ pmId b)
                   else compare (pmTimestamp a) (pmTimestamp b)

-- | Gissip message periodically sent to random active nodes.
data PrmGossipMessage = PrmGossipMessage {
    pgmNid           :: !NodeId               -- ^ Source Node.
  , pgmGossip        :: ![PrmMessage]         -- ^ Gossip with newly received patckets.
  , pgmMissingPacket :: !(Maybe PrmMessageId) -- ^ 'PrmMessageId' of a random missing packet.
  , pgmActiveView    :: !NodeId               -- ^ Random entry from Active View
  , pgmPassiveView   :: !(Maybe NodeId)       -- ^ Random entry from Passive View
} deriving (Typeable, Generic, Show)

instance NFData PrmGossipMessage

instance Binary PrmGossipMessage

-- | Create a 'PrmCtx' structure, and register the "prmListenser" service.
prmInitialize ::  Int -> Int -> Int -> Int -> Process (MVar PrmCtx)
prmInitialize  seed fanout gossipInterval quiescense = do
  ctx <- liftIO $ newMVar PrmCtx { pcClock = PrmTimestamp 0
                                 , pcSeq   = PrmSequenceNumber 0
                                 , pcBufferNew = M.empty
                                 , pcBufferOld = M.empty
                                 , pcActiveView = []
                                 , pcPassiveView = []
                                 , pcFanout      = fanout
                                 , pcGossipInterval = gossipInterval
                                 , pcQuiescense = quiescense
                                 }
  gosiper <- spawnLocal $ prmGossiper seed ctx
  pid <- getSelfPid
  register "prmListener" pid

  return ctx

-- | Connect to the "prmListenser" service on the ginve 'NodeId'
prmWaitForPeer :: MVar PrmCtx -> NodeId -> Process ()
prmWaitForPeer ctx nid = do
  whereisRemoteAsync nid "prmListener"
  WhereIsReply reason pid_m <- expect
  case pid_m of
       Nothing -> do
         say'$ printf "whereisRemoteAsync failed to %s %s" (show nid) reason
         liftIO $ threadDelay 1000000
       Just pid -> do
         liftIO $ modifyMVar_ ctx
             (\c -> return $ c {pcActiveView = (nid,pid) : pcActiveView c})
         _ <- monitor pid -- XXX hold on to the ref
         return ()

-- | Simulate link faults by randomly removing a peer from active view every 5s.
-- | Stops after reaching the specified failure rate.
prmSimulatedLinkFaults :: Int -> MVar PrmCtx -> Int -> Double -> Process ()
prmSimulatedLinkFaults seed ctx numberOfPeers linkFailureRate = do
  let rng = mkStdGen seed
  let faultyLinks = round $ fromIntegral numberOfPeers * linkFailureRate / 100
  loop rng faultyLinks
  where
    loop rng faultyLinks = do
      liftIO $ threadDelay 5000000
      when (faultyLinks > 0) $ do
        ctx_ <- liftIO $ takeMVar ctx
        let av = pcActiveView ctx_
        let (av', rng') = runRand (grabbleOnce av (length av - 1)) rng
        liftIO $ putMVar ctx $ ctx_ {pcActiveView = av' }
        say' $ printf "removing peer %s" (show $ head $ (L.\\) av av')
        loop rng' (faultyLinks - 1)

-- | Send a message to all actice peers
prmSend :: MVar PrmCtx -> Double -> Process ()
prmSend ctx v = do
  src <- force nodeAddress <$> getSelfNode
  ctx_ <- liftIO $ takeMVar ctx
  let !ts = prmTsInc  $ pcClock ctx_
  let !sq = prmSeqInc $ pcSeq ctx_
  let !pim = prmMessageId src sq
  let !msg = PrmMessage pim ts v
  let !ctx' = ctx_ { pcClock = ts
                   , pcSeq   = sq
                   , pcBufferOld = M.insert pim (Just msg) (pcBufferOld ctx_)
                   }
  liftIO $ putMVar ctx $ force ctx'

  av <- liftIO $ pcActiveView <$> readMVar ctx
  mapM_ (\(_,dst) -> send dst msg) av
  return ()

-- | Return a sorted list of all received messages
prmGetMessages :: MVar PrmCtx -> Process [PrmMessage]
prmGetMessages ctx = do
  res <- liftIO $ pcBufferOld <$> readMVar ctx
  return $ L.sort $ map fromJust $ M.elems $ M.filter isJust res

-- | Periodically gossip about recent 'PrmMessage' with 'pcFanout' peers.
prmGossiper :: Int -> MVar PrmCtx -> Process ()
prmGossiper seed ctx = do
  let rng = mkStdGen seed
  doGossip rng
  where
    doGossip rng = do
      sleep <- liftIO $ pcGossipInterval <$> readMVar ctx
      liftIO $ threadDelay sleep
      ctx_ <- liftIO $ takeMVar ctx
      let haveGossip = not . M.null $ pcBufferNew ctx_
      if haveGossip && pcActiveView ctx_ /= []
         then do
           !src <- getSelfNode
           let bn = pcBufferNew ctx_
               gossip = M.keys bn
               av = pcActiveView ctx_

               -- The paper states that the we should make a pull request for
               -- the latest know missing packet, but I suspect that scoring
               -- will be done based on the longest correct streak of values
               -- so the latest missing packet may be worthless. If we instead
               -- asked for the first missing packet we risk beeing stuck on a
               -- permanently lost packet. Instead we ask for a random missing
               -- packet.
               missings = M.keys $ M.filter isNothing $ pcBufferOld ctx_
               (mp, rng') = runRand (grabbleOnce missings 1) rng
               missing = listToMaybe mp
               (avSample, rng'') = runRand (grabbleOnce av 1) rng'
               (pvSample, rng''') = runRand (grabbleOnce (pcPassiveView ctx_) 1) rng''
           when (isJust missing) $
             say' $ printf "looking for %s" (show missing)
           let msg = PrmGossipMessage src gossip missing (fst $ head avSample)
                                      (listToMaybe pvSample)
           -- pick pcFanout random peers to gossip with
           let !(dsts, rng'''') = runRand (grabbleOnce av $ pcFanout ctx_) rng'''
           liftIO $ putMVar ctx $ ctx_ {pcBufferNew = M.mapMaybe (ageMessage ctx_) bn}
           mapM_ (\(_,dst) -> send dst msg) dsts
           doGossip rng''''
         else do
           liftIO $ putMVar ctx ctx_
           doGossip rng

    ageMessage :: PrmCtx -> Int -> Maybe Int
    ageMessage ctx age =
      if age >= pcQuiescense ctx then Nothing
                                 else Just $! age + 1

-- | Wait for delay ns, receiving 'PrmMessage'.
prmReceiveTimeout :: MVar PrmCtx -> Int -> Process ()
prmReceiveTimeout ctx delay | delay <= 0 = return ()
prmReceiveTimeout ctx delay = do
  !start <- liftIO getCurrentTime
  r <- receiveTimeout delay [match recieveGossip, match receiveBroadcast, match recieveMonitorNotifications]
  !end <- liftIO getCurrentTime
  case r of
       Nothing -> return ()
       Just _  -> do
         let delay' = delay - round ((realToFrac $ diffUTCTime end start) :: Double)
         prmReceiveTimeout ctx delay'
  where

    recieveMonitorNotifications :: ProcessMonitorNotification -> Process ()
    recieveMonitorNotifications (ProcessMonitorNotification _ pid reason) = do
      say' $ printf "Process %s died of %s" (show pid) (show reason)
      case reason of
           DiedDisconnect -> reconnect pid -- We got disconnected, attempt to reconnect
           _              -> do
             -- Move processes/nodes that have been terminated out of the active view.
             ctx_ <- liftIO $ takeMVar ctx
             let (dead,alive) = L.partition (\(_,p) -> p == pid) $ pcActiveView ctx_
             let ctx' = if dead /= []
                           then ctx_ { pcActiveView  = alive
                                     , pcPassiveView = map fst dead ++ pcPassiveView ctx_}
                           else ctx_
             liftIO $ putMVar ctx ctx'
             return ()

    recieveGossip :: PrmGossipMessage -> Process ()
    recieveGossip msg = do
      ctx_ <- liftIO $ takeMVar ctx
      ctx' <- foldM updateBuffers ctx_ (pgmGossip msg)
      respondToPull ctx' msg
      liftIO $ putMVar ctx ctx'

    receiveBroadcast :: PrmMessage -> Process ()
    receiveBroadcast msg =  do
      ctx_ <- liftIO $ takeMVar ctx
      ctx' <- receiveBroadcast' ctx_ msg
      liftIO $ putMVar ctx ctx'

    receiveBroadcast' :: PrmCtx -> PrmMessage -> Process PrmCtx
    receiveBroadcast' ctx_ msg =  do
      let msg_ = prmMessageDuplicate msg
      case M.lookup (pmId msg_) (pcBufferOld ctx_) of
           Just (Just _) -> return ctx_ -- we've already seen this packet
           orherwise     -> do
             let possibleSeq = map PrmSequenceNumber [1 .. unSeq $ pmiSeq $ pmId msg_]
             let bufferOld = M.insert (pmId msg_) (Just msg_) (pcBufferOld ctx_)
             bufferOld' <- foldM (trackSequenseNumbers (pmiNid $ pmId msg_)) bufferOld
                                 possibleSeq
             let ctx' = ctx_ { pcClock = prmTsInc $ max (pmTimestamp msg_)
                                                        (pcClock ctx_)
                             , pcBufferNew =  M.insert msg_ 0 (pcBufferNew ctx_)
                             , pcBufferOld = bufferOld'
                             }
             return ctx'

    updateBuffers :: PrmCtx -> PrmMessage -> Process PrmCtx
    updateBuffers ctx msg =
      case M.lookup (pmId msg) (pcBufferOld ctx) of
         Just (Just _) -> return ctx           -- We have sen this packet
         Just Nothing  -> do
           say' $ printf "gossiping got known missing pkt %s" (show msg)
           receiveBroadcast' ctx msg
         Nothing       -> do
           --say' $ printf "gossiping got unknown missing pkt %s" (show msg)
           receiveBroadcast' ctx msg

    respondToPull :: PrmCtx -> PrmGossipMessage -> Process ()
    respondToPull ctx_ msg | isNothing $ pgmMissingPacket msg = return ()
    respondToPull ctx_ msg = do
      say' $ printf "gossip pull for %s" (show $ pgmMissingPacket msg)
      let reply_m = ((\pid -> M.lookup pid (pcBufferOld ctx_)) <=< pgmMissingPacket) msg
      case reply_m of
           Nothing           -> say' $ printf "gossip pull for unknown packet %s" (show msg)
           Just (Just reply) -> do
             let av = pcActiveView ctx_
             let !dst_m = L.find (\(nid,_) -> nid == pgmNid msg) av
             case dst_m of
                  Nothing      -> return ()    -- We don't know this peer
                  Just (_,dst) -> do
                    say'"responding to gossip pull request"
                    send dst reply
           Just Nothing      -> return () -- We know of the packet but we don't have it

    trackSequenseNumbers :: EndPointAddress -> PrmBufferOld ->
                            PrmSequenceNumber -> Process PrmBufferOld
    trackSequenseNumbers epa m sq =
      let mid = PrmMessageId epa sq in
      case M.lookup mid m of
           Nothing -> do
             say' $ printf "inserting marker for missing packet %s" (show mid)
             return $ M.insert mid Nothing m -- Insert a marker so we can start asking this
           Just _  -> return m               -- We have this packet


