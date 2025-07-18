{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

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
import qualified Data.ByteString as BS
import Data.Aeson 
import qualified System.Process as S
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy.Char8 as BL

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
  Just cmd -> flip catchError (errHdl cmd) $ do
    lift (go cmd) >>= yield >> cmd2task
  Nothing -> do
    $logWarnS DM._LOGTAG "cmd2task: await returns nothing. skip."
    cmd2task

  where
    errHdl :: DM.ProcSpawnCommand -> String -> ConduitT DM.ProcSpawnCommand (IOTask ()) AppContext ()
    errHdl procCmd msg = do
      let jsonrpc = DM.getJsonRpcProcSpawnCommand procCmd
      $logWarnS DM._LOGTAG $ T.pack $ "cmd2task: exception occurred. skip. " ++ msg
      lift $ errorToolsCallResponse jsonrpc $ "cmd2task: exception occurred. skip. " ++ msg
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

  toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcEchoCommandData) ExitSuccess val ""

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.echoTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcEchoCommandData) (ExitFailure 1) "" (show e)

-- |
--
genProcRunTask :: DM.ProcRunCommandData -> AppContext (IOTask ())
genProcRunTask cmdDat = case cmdDat^.DM.nameProcRunCommandData of
  "proc-spawn"  -> genProcSpawn cmdDat
  "proc-ssh"    -> genProcSpawn cmdDat
  "proc-telnet" -> genProcTelnet cmdDat
  "proc-cmd"    -> genProcCMD cmdDat
  "proc-ps"     -> genProcPS cmdDat
  x -> throwError $ "genProcRunTask: unsupported command. " ++ x


-- |
--   
genProcSpawn :: DM.ProcRunCommandData -> AppContext (IOTask ())
genProcSpawn cmdDat = do
  let name     = cmdDat^.DM.nameProcRunCommandData
      argsBS   = DM.unRawJsonByteString $ cmdDat^.DM.argumentsProcRunCommandData
      tout     = DM._TIMEOUT_MICROSEC
      addEnv   = [("ProgramData", "C:\\ProgramData"), ("SystemRoot", "C:\\Windows")] -- for windows ssh on claude code.

  prompts   <- view DM.promptsDomainData <$> lift ask
  resQ      <- view DM.responseQueueDomainData <$> lift ask
  procMVar  <- view processAppData <$> ask
  lockTMVar <- view lockAppData <$> ask

  (cmdTmp, argsArrayTmp, addPrompts)  <- getCommandArgs name argsBS
  cmd <- liftIOE $ DM.validateCommand cmdTmp
  argsArray <- liftIOE $ DM.validateArgs argsArrayTmp

  $logDebugS DM._LOGTAG $ T.pack $ "genProcRunTask: cmd. " ++ cmd ++ " " ++ show argsArray
 
  return $ procSpawnTask cmdDat resQ procMVar lockTMVar cmd argsArray addEnv (prompts++addPrompts) tout

  where
    -- |
    --
    getCommandArgs :: String -> BL.ByteString -> AppContext (String, [String], [String])
    getCommandArgs "proc-spawn" argsBS = do
      argsDat <- liftEither $ eitherDecode $ argsBS
      let argsArray = maybe [] id (argsDat^.argumentsProcCommandToolParams)
          cmd = argsDat^.commandProcCommandToolParams
      return (cmd, argsArray, [])

    getCommandArgs "proc-ssh" argsBS = do
      argsDat <- liftEither $ eitherDecode $ argsBS
      let argsArray0 = argsDat ^. argumentsProcStringArrayToolParams
          argsArray  = if "-tt" `elem` argsArray0 then argsArray0 else "-tt" : argsArray0
      return ("ssh", argsArray, [")?", "password:"])
      -- return ("ssh", ["-o", "LogLevel=DEBUG", "-v"] ++ argsArray, [")?", "password:"])

    getCommandArgs "proc-telnet" argsBS = do
      argsDat <- liftEither $ eitherDecode $ argsBS
      let argsArray = argsDat^.argumentsProcStringArrayToolParams
      return ("telnet", argsArray, ["login:", "Password:"])

    getCommandArgs x _ = throwError $ "getCommandArgs: unsupported command. " ++ x


-- |
--   
procSpawnTask :: DM.ProcRunCommandData
              -> STM.TQueue DM.McpResponse
              -> STM.TMVar (Maybe ProcData)
              -> STM.TMVar ()
              -> String
              -> [String]
              -> [(String, String)]
              -> [String]
              -> Int
              -> IOTask ()
procSpawnTask cmdDat resQ procVar lockTMVar cmd args addEnv prompts tout = do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.procSpawnTask start. "

  STM.atomically (STM.takeTMVar procVar) >>= \case
    Just p -> do
      STM.atomically $ STM.putTMVar procVar $ Just p
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.procSpawnTask: pms is already connected."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "process is already running."
    Nothing -> do
      flip E.catchAny errHdl $ runProc procVar cmd args addEnv

  STM.atomically (STM.readTMVar procVar) >>= \case
    Just p -> do
      race (DM.expect lockTMVar (readProc p) prompts) (CC.threadDelay tout) >>= \case
        Left res -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) ExitSuccess (maybe "Nothing" id res) ""
        Right _  -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "timeout occurred."
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.procSpawnTask: unexpected. proc not found."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "unexpected. proc not found."

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procSpawnTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = do
      STM.atomically $ STM.putTMVar procVar Nothing
      hPutStrLn stderr $ "[ERROR] PMS.Infra.ProcSpawn.DS.Core.procRunTask: exception occurred. " ++ show e
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" (show e)


-- |
--   
genProcCMD :: DM.ProcRunCommandData -> AppContext (IOTask ())
genProcCMD cmdDat = do
  $logDebugS DM._LOGTAG $ T.pack $ "genProcCMD: called. "

  let tout = DM._TIMEOUT_MICROSEC

  prompts <- view DM.promptsDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  procMVar <- view processAppData <$> ask
  lockTMVar <- view lockAppData <$> ask
  
  return $ genProcCMDTask cmdDat resQ procMVar lockTMVar prompts tout

-- |
--   
genProcCMDTask :: DM.ProcRunCommandData
               -> STM.TQueue DM.McpResponse
               -> STM.TMVar (Maybe ProcData)
               -> STM.TMVar ()
               -> [String]
               -> Int
               -> IOTask ()
genProcCMDTask cmdDat resQ procVar lockTMVar prompts tout = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask start. "

  STM.atomically (STM.takeTMVar procVar) >>= \case
    Just p -> do
      STM.atomically $ STM.putTMVar procVar $ Just p
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask: process is already running."
      E.throwString "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask: process is already running."
    Nothing -> runProc procVar "cmd" [] []

  STM.atomically (STM.readTMVar procVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask: process is not started."
      E.throwString "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask: process is not started."
    Just procDat -> do
      let wHdl = procDat^.wHdLProcData
          msg  =  "chcp 65001 & prompt $P$G$G$G"
          cmd  = TE.encodeUtf8 $ T.pack $ msg ++ DM._LF
      
      hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask writeProc : " ++ BS8.unpack cmd
      BS.hPut wHdl cmd
      hFlush wHdl

  STM.atomically (STM.readTMVar procVar) >>= \case
    Just p -> race (DM.expect lockTMVar (readProc p) prompts) (CC.threadDelay tout) >>= \case
      Left res -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) ExitSuccess (maybe "Nothing" id res) ""
      Right _  -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "timeout occurred."
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.genProcCMDTask: unexpected. proc not found."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "unexpected. proc not found."

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = do
      STM.atomically $ STM.putTMVar procVar Nothing
      hPutStrLn stderr $ "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcCMDTask: exception occurred. " ++ show e
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" (show e)



-- |
--   
genProcTelnet :: DM.ProcRunCommandData -> AppContext (IOTask ())
genProcTelnet cmdDat = do
  $logDebugS DM._LOGTAG $ T.pack $ "genProcTelnet: called. "

  let tout = DM._TIMEOUT_MICROSEC

  prompts <- view DM.promptsDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  procMVar <- view processAppData <$> ask
  lockTMVar <- view lockAppData <$> ask
  
  return $ genProcTelnetTask cmdDat resQ procMVar lockTMVar prompts tout


-- |
--   
genProcTelnetTask :: DM.ProcRunCommandData
               -> STM.TQueue DM.McpResponse
               -> STM.TMVar (Maybe ProcData)
               -> STM.TMVar ()
               -> [String]
               -> Int
               -> IOTask ()
genProcTelnetTask cmdDat resQ procVar lockTMVar prompts tout = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask start. "

  STM.atomically (STM.takeTMVar procVar) >>= \case
    Just p -> do
      STM.atomically $ STM.putTMVar procVar $ Just p
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask: process is already running."
      E.throwString "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask: process is already running."
    Nothing -> runProc procVar "telnet" ["xxx.xxx.xxx.xxx"] []

  STM.atomically (STM.readTMVar procVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask: process is not started."
      E.throwString "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask: process is not started."
    Just procDat -> do
      let wHdl = procDat^.wHdLProcData
          msg  =  "phoityne"
          cmd  = TE.encodeUtf8 $ T.pack $ msg ++ DM._LF
      
      hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask username : " ++ BS8.unpack cmd
      BS.hPut wHdl cmd
      hFlush wHdl

  STM.atomically (STM.readTMVar procVar) >>= \case
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask: process is not started."
      E.throwString "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask: process is not started."
    Just procDat -> do
      let wHdl = procDat^.wHdLProcData
          msg  =  "1qaz2wsx"
          cmd  = TE.encodeUtf8 $ T.pack $ msg ++ DM._LF
      
      hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask password : " ++ BS8.unpack cmd
      BS.hPut wHdl cmd
      hFlush wHdl

  STM.atomically (STM.readTMVar procVar) >>= \case
    Just p -> race (DM.expect lockTMVar (readProc p) prompts) (CC.threadDelay tout) >>= \case
      Left res -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) ExitSuccess (maybe "Nothing" id res) ""
      Right _  -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "timeout occurred."
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.genProcTelnetTask: unexpected. proc not found."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "unexpected. proc not found."

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = do
      STM.atomically $ STM.putTMVar procVar Nothing
      hPutStrLn stderr $ "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcTelnetTask: exception occurred. " ++ show e
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" (show e)


-- |
--   
genProcPS :: DM.ProcRunCommandData -> AppContext (IOTask ())
genProcPS cmdDat = do
  $logDebugS DM._LOGTAG $ T.pack $ "genProcPS: called. "

  let tout = DM._TIMEOUT_MICROSEC

  prompts <- view DM.promptsDomainData <$> lift ask
  resQ <- view DM.responseQueueDomainData <$> lift ask
  procMVar <- view processAppData <$> ask
  lockTMVar <- view lockAppData <$> ask
  
  return $ genProcPSTask cmdDat resQ procMVar lockTMVar prompts tout

-- |
--   
genProcPSTask :: DM.ProcRunCommandData
               -> STM.TQueue DM.McpResponse
               -> STM.TMVar (Maybe ProcData)
               -> STM.TMVar ()
               -> [String]
               -> Int
               -> IOTask ()
genProcPSTask cmdDat resQ procVar lockTMVar prompts tout = flip E.catchAny errHdl $ do
  hPutStrLn stderr $ "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcPSTask start. "
  let initCmd = "chcp 65001; $OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; function prompt { \"PS $((Get-Location).Path)>>>\" }"

  STM.atomically (STM.takeTMVar procVar) >>= \case
    Just p -> do
      STM.atomically $ STM.putTMVar procVar $ Just p
      hPutStrLn stderr "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcPSTask: process is already running."
      E.throwString "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcPSTask: process is already running."
    Nothing -> runProc procVar "powershell" ["-NoLogo", "-NoExit", "-Command", initCmd] []

  STM.atomically (STM.readTMVar procVar) >>= \case
    Just p -> race (DM.expect lockTMVar (readProc p) prompts) (CC.threadDelay tout) >>= \case
      Left res -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) ExitSuccess (maybe "Nothing" id res) ""
      Right _  -> toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "timeout occurred."
    Nothing -> do
      hPutStrLn stderr "[ERROR] PMS.Infrastructure.DS.Core.genProcPSTask: unexpected. proc not found."
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" "unexpected. proc not found."

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.genProcPSTask end."

  where
    errHdl :: E.SomeException -> IO ()
    errHdl e = do
      STM.atomically $ STM.putTMVar procVar Nothing
      hPutStrLn stderr $ "[ERROR] PMS.Infra.ProcSpawn.DS.Core.genProcPSTask: exception occurred. " ++ show e
      toolsCallResponse resQ (cmdDat^.DM.jsonrpcProcRunCommandData) (ExitFailure 1) "" (show e)

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
  let args = argsDat^.argumentsProcStringToolParams

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
