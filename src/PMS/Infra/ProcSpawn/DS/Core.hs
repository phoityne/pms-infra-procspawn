{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

module PMS.Infra.ProcSpawn.DS.Core where

import System.IO
import Control.Monad.Logger
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Lens
import Control.Monad.Reader
import qualified Control.Concurrent as CC 
import Control.Concurrent.Async
import qualified Control.Concurrent.STM as STM
import Data.Conduit
import qualified Data.Text as T
import Control.Monad.Except
import qualified Control.Exception.Safe as E
import System.Exit
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import Data.Aeson 
import qualified System.Process as S
import qualified Data.ByteString.Char8 as BS8

import qualified PMS.Domain.Model.DS.Utility as DM
import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.Constant as DM

import PMS.Infra.ProcSpawn.DM.Type
import PMS.Infra.ProcSpawn.DS.Utility


-- |
--
app :: AppContext ()
app = do
  $logDebugS DM._LOGTAG "app called."
  runConduit pipeline
  where
    pipeline :: ConduitM () Void AppContext ()
    pipeline = src .| cmd2task .| sink

---------------------------------------------------------------------------------
-- |
--
src :: ConduitT () DM.ProcSpawnCommand AppContext ()
src = lift go >>= yield >> src
  where
    go :: AppContext DM.ProcSpawnCommand
    go = do
      queue <- view DM.procspawnQueueDomainData <$> lift ask
      dat <- liftIO $ STM.atomically $ STM.readTQueue queue
      -- let jsonrpc = DM.getJsonRpcProcSpawnCommand dat
      
      return dat

---------------------------------------------------------------------------------
-- |
--
cmd2task :: ConduitT DM.ProcSpawnCommand (IOTask ()) AppContext ()
cmd2task = await >>= \case
  Just cmd -> flip catchError errHdl $ do
    lift (go cmd) >>= yield >> cmd2task
  Nothing -> do
    $logWarnS DM._LOGTAG "cmd2task: await returns nothing. skip."
    cmd2task

  where
    errHdl :: String -> ConduitT DM.ProcSpawnCommand (IOTask ()) AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "cmd2task: exception occurred. skip. " ++ msg
      cmd2task

    go :: DM.ProcSpawnCommand -> AppContext (IOTask ())
    go (DM.ProcEchoCommand dat)      = genEchoTask dat
    go (DM.ProcRunCommand dat)       = genProcRunTask dat
    go (DM.ProcTerminateCommand dat) = genProcTerminateTask dat
    go (DM.ProcMessageCommand dat)   = genProcMessageTask dat

---------------------------------------------------------------------------------
-- |
--
sink :: ConduitT (IOTask ()) Void AppContext ()
sink = await >>= \case
  Just req -> flip catchError errHdl $ do
    lift (go req) >> sink
  Nothing -> do
    $logWarnS DM._LOGTAG "sink: await returns nothing. skip."
    sink

  where
    errHdl :: String -> ConduitT (IOTask ()) Void AppContext ()
    errHdl msg = do
      $logWarnS DM._LOGTAG $ T.pack $ "sink: exception occurred. skip. " ++ msg
      sink

    go :: (IO ()) -> AppContext ()
    go task = do
      $logDebugS DM._LOGTAG "sink: start async."
      _ <- liftIOE $ async task
      $logDebugS DM._LOGTAG "sink: end async."
      return ()

---------------------------------------------------------------------------------
-- |
--
toolsCallResponse :: STM.TQueue DM.McpResponse
                  -> DM.JsonRpcRequest
                  -> ExitCode
                  -> String
                  -> String
                  -> IO ()
toolsCallResponse resQ jsonRpc code outStr errStr = do
  let content = [ DM.McpToolsCallResponseResultContent "text" outStr
                , DM.McpToolsCallResponseResultContent "text" errStr
                ]
      result = DM.McpToolsCallResponseResult {
                  DM._contentMcpToolsCallResponseResult = content
                , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                }
      resDat = DM.McpToolsCallResponseData jsonRpc result
      res = DM.McpToolsCallResponse resDat

  STM.atomically $ STM.writeTQueue resQ res

-- |
--
errorToolsCallResponse :: String -> AppContext ()
errorToolsCallResponse errStr = do
  jsonRpc <- view jsonrpcAppData <$> ask
  let content = [ DM.McpToolsCallResponseResultContent "text" errStr ]
      result = DM.McpToolsCallResponseResult {
                  DM._contentMcpToolsCallResponseResult = content
                , DM._isErrorMcpToolsCallResponseResult = True
                }
      resDat = DM.McpToolsCallResponseData jsonRpc result
      res = DM.McpToolsCallResponse resDat

  resQ <- view DM.responseQueueDomainData <$> lift ask
  liftIOE $ STM.atomically $ STM.writeTQueue resQ res

---------------------------------------------------------------------------------
-- |
--
genEchoTask :: DM.ProcEchoCommandData -> AppContext (IOTask ())
genEchoTask dat = do
  resQ <- view DM.responseQueueDomainData <$> lift ask
  let val = dat^.DM.valueProcEchoCommandData

  $logDebugS DM._LOGTAG $ T.pack $ "echoTask: echo : " ++ val
  return $ echoTask resQ dat val


-- |
--
echoTask :: STM.TQueue DM.McpResponse -> DM.ProcEchoCommandData -> String -> IOTask ()
echoTask resQ cmdDat val = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.echoTask run. " ++ val

  response ExitSuccess val ""

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.echoTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = response (ExitFailure 1) "" (show e)

    response :: ExitCode -> String -> String -> IO ()
    response code outStr errStr = do
      let jsonRpc = cmdDat^.DM.jsonrpcProcEchoCommandData
          content = [ DM.McpToolsCallResponseResultContent "text" outStr
                    , DM.McpToolsCallResponseResultContent "text" errStr
                    ]
          result = DM.McpToolsCallResponseResult {
                      DM._contentMcpToolsCallResponseResult = content
                    , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                    }
          resDat = DM.McpToolsCallResponseData jsonRpc result
          res = DM.McpToolsCallResponse resDat

      STM.atomically $ STM.writeTQueue resQ res

-- |
--
genProcRunTask :: DM.ProcRunCommandData -> AppContext (IOTask ())
genProcRunTask dat = do
  let name     = dat^.DM.nameProcRunCommandData
      argsBS   = DM.unRawJsonByteString $ dat^.DM.argumentsProcRunCommandData
      tout     = 30 * 1000 * 1000

  prompts <- view DM.promptsDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  procMVar <- view processAppData <$> ask
  lockTMVar <- view lockAppData <$> ask

  (cmdTmp, argsArrayTmp)  <- getCommandArgs name argsBS
  cmd <- liftIOE $ DM.validateCommand cmdTmp
  argsArray <- liftIOE $ DM.validateArgs argsArrayTmp

  $logDebugS DM._LOGTAG $ T.pack $ "genProcRunTask: cmd. " ++ cmd ++ " " ++ show argsArray
 
  return $ procRunTask dat resQ procMVar lockTMVar cmd argsArray prompts tout

  where
    -- | Get command and arguments from the given name and arguments.
    getCommandArgs :: String -> BL.ByteString -> AppContext (String, [String])
    getCommandArgs "proc-spawn" argsBS = do
      argsDat <- liftEither $ eitherDecode $ argsBS
      let argsArray = maybe [] id (argsDat^.argumentsProcCommandToolParams)
          cmd = argsDat^.commandProcCommandToolParams
      return (cmd, argsArray)
    getCommandArgs x _ = throwError $ "getCommand: unsupported command. " ++ x


-- |
--   
procRunTask :: DM.ProcRunCommandData
            -> STM.TQueue DM.McpResponse
            -> STM.TMVar (Maybe ProcData)
            -> STM.TMVar ()
            -> String
            -> [String]
            -> [String]
            -> Int
            -> IOTask ()
procRunTask cmdDat resQ procVar lockTMVar cmd args prompts tout = do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.procRunTask start. "

  STM.atomically (STM.takeTMVar procVar) >>= \case
    Just p -> do
      STM.atomically $ STM.putTMVar procVar $ Just p
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.work.ptyConnectTask: pms is already connected."
      response (ExitFailure 1) "" "process is already running."
    Nothing -> E.catchAny runProc errHdl

  STM.atomically (STM.readTMVar procVar) >>= \case
    Just p -> race (DM.expect lockTMVar (readProc p) prompts) (CC.threadDelay tout) >>= \case
      Left res -> response ExitSuccess (maybe "Nothing" id res) ""
      Right _  -> response (ExitFailure 1) "" "timeout occurred."
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.work.ptyConnectTask: unexpected. proc not found."
      response (ExitFailure 1) "" "unexpected. proc not found."

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procRunTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = do
      STM.atomically $ STM.putTMVar procVar Nothing
      hPutStrLn stderr $ "[ERROR] PMS.Infra.ProcSpawn.DS.Core.procRunTask.runProc: exception occurred. " ++ show e
      response (ExitFailure 1) "" (show e)

    runProc :: IO ()
    runProc = do
      hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procRunTask.runProc start."
      (fromPmsHandle, toProcHandle) <- S.createPipe
      (fromProcHandle, toPmsHandle) <- S.createPipe
      let cwd = Nothing
          runEnvs = Nothing
{-
      osEnc <- mkTextEncoding "UTF-8//TRANSLIT"

      let runEnvs = Nothing
          bufMode = S.NoBuffering
      --let bufMode = S.BlockBuffering $ Just 1024

      S.hSetBuffering toPhoityneHandle bufMode
      S.hSetEncoding toPhoityneHandle osEnc
      S.hSetNewlineMode toPhoityneHandle $ S.NewlineMode S.CRLF S.LF
      --S.hSetBinaryMode toPhoityneHandle True

      S.hSetBuffering fromPhoityneHandle bufMode
      S.hSetEncoding fromPhoityneHandle  S.utf8
      S.hSetNewlineMode fromPhoityneHandle $ S.NewlineMode S.LF S.LF
      --S.hSetBinaryMode fromPhoityneHandle True

      S.hSetBuffering toGHCiHandle bufMode
      S.hSetEncoding toGHCiHandle S.utf8
      S.hSetNewlineMode toGHCiHandle $ S.NewlineMode S.LF S.LF
      --S.hSetBinaryMode toGHCiHandle True

      S.hSetBuffering fromGHCiHandle bufMode
      S.hSetEncoding fromGHCiHandle osEnc
      S.hSetNewlineMode fromGHCiHandle $ S.NewlineMode S.CRLF S.LF
      --S.hSetBinaryMode fromGHCiHandle True
-}
      pHdl <- S.runProcess cmd args cwd runEnvs (Just fromPmsHandle) (Just toPmsHandle) (Just toPmsHandle)
      let procData = ProcData {
                     _wHdLProcData = toProcHandle
                   , _rHdlProcData = fromProcHandle
                   , _eHdlProcData = fromProcHandle
                   , _pHdlProcData = pHdl
                   }
      STM.atomically $ STM.putTMVar procVar (Just procData)

      hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procRunTask.runProc end."

    response :: ExitCode -> String -> String -> IO ()
    response code outStr errStr = do
      let jsonRpc = cmdDat^.DM.jsonrpcProcRunCommandData
          content = [ DM.McpToolsCallResponseResultContent "text" outStr
                    , DM.McpToolsCallResponseResultContent "text" errStr
                    ]
          result = DM.McpToolsCallResponseResult {
                      DM._contentMcpToolsCallResponseResult = content
                    , DM._isErrorMcpToolsCallResponseResult = (ExitSuccess /= code)
                    }
          resDat = DM.McpToolsCallResponseData jsonRpc result
          res = DM.McpToolsCallResponse resDat

      STM.atomically $ STM.writeTQueue resQ res

-- |
--   
readProc :: ProcData -> IO BS.ByteString
readProc dat = do
  let hdl = dat^.rHdlProcData
  BS.hGetSome hdl 4096


-- |
--
genProcTerminateTask :: DM.ProcTerminateCommandData -> AppContext (IOTask ())
genProcTerminateTask dat = do
  $logDebugS DM._LOGTAG $ T.pack $ "genProcTerminateTask called. "
  procTMVar <- view processAppData <$> ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  return $ procTerminateTask dat resQ procTMVar

-- |
--
procTerminateTask :: DM.ProcTerminateCommandData
                  -> STM.TQueue DM.McpResponse
                  -> STM.TMVar (Maybe ProcData)
                  -> IOTask ()
procTerminateTask cmdDat resQ procTMVar = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.procTerminateTask run. "
  let jsonRpc = cmdDat^.DM.jsonrpcProcTerminateCommandData

  STM.atomically (STM.swapTMVar procTMVar Nothing) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.procTerminateTask: process is not started."
      toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "process is not started."
    Just procDat -> do
      let pHdl = procDat^.pHdlProcData
      S.terminateProcess pHdl
      exitCode <- S.waitForProcess pHdl
      toolsCallResponse resQ jsonRpc exitCode "" "process is teminated."
      hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.procTerminateTask closeProc : " ++ show exitCode

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procTerminateTask end."

  where
    -- |
    --
    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcTerminateCommandData) (ExitFailure 1) "" (show e)


-- |
--
genProcMessageTask :: DM.ProcMessageCommandData -> AppContext (IOTask ())
genProcMessageTask cmdData = do
  let argsBS = DM.unRawJsonByteString $ cmdData^.DM.argumentsProcMessageCommandData
      tout = 30 * 1000 * 1000
  prompts <- view DM.promptsDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  procTMVar <- view processAppData <$> ask
  lockTMVar <- view lockAppData <$> ask
  argsDat <- liftEither $ eitherDecode $ argsBS
  let args = argsDat^.argumentsStringToolParams

  $logDebugS DM._LOGTAG $ T.pack $ "genProcMessageTask: args. " ++ args
  return $ procMessageTask cmdData resQ procTMVar lockTMVar args prompts tout

-- |
--
procMessageTask :: DM.ProcMessageCommandData
                -> STM.TQueue DM.McpResponse
                -> STM.TMVar (Maybe ProcData)
                -> STM.TMVar ()
                -> String  -- arguments line
                -> [String]  -- prompt list
                -> Int       -- timeout microsec
                -> IOTask ()
procMessageTask cmdDat resQ procTMVar lockTMVar args prompts tout = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.procMessageTask run. " ++ args
    
  STM.atomically (STM.readTMVar procTMVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.procMessageTask: process is not started."
      toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "process is not started."
    Just p -> go p

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procMessageTask end."

  where
    jsonRpc :: DM.JsonRpcRequest
    jsonRpc = cmdDat^.DM.jsonrpcProcMessageCommandData

    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ jsonRpc (ExitFailure 1) "" (show e)

    go :: ProcData -> IO ()
    go pDat = do
      let wHdl = pDat^.wHdLProcData

      msg <- DM.validateMessage args
      let cmd = TE.encodeUtf8 $ T.pack $ msg ++ DM._LF

      hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.procMessageTask writeProc : " ++ BS8.unpack cmd

      BS.hPut wHdl cmd
      hFlush wHdl

      race (DM.expect lockTMVar (readProc pDat) prompts) (CC.threadDelay tout) >>= \case
        Left res -> toolsCallResponse resQ jsonRpc ExitSuccess (maybe "Nothing" id res) ""
        Right _  -> toolsCallResponse resQ jsonRpc (ExitFailure 1) "" "timeout occurred."
