{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module PMS.Infra.ProcSpawn.DS.Utility where

import System.IO
import Control.Lens
import System.Exit
import System.Log.FastLogger
import qualified Control.Exception.Safe as E
import Control.Monad.IO.Class
import Control.Monad.Except
import Control.Monad.Reader
import qualified Control.Concurrent.STM as STM
import qualified System.Process as S
import qualified Data.ByteString as BS
import qualified System.Environment as Env

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DS.Utility as DM
import PMS.Infra.ProcSpawn.DM.Type

-- |
--
runApp :: DM.DomainData -> AppData -> TimedFastLogger -> AppContext a -> IO (Either DM.ErrorData a)
runApp domDat appDat logger ctx =
  DM.runFastLoggerT domDat logger
    $ runExceptT
    $ flip runReaderT domDat
    $ runReaderT ctx appDat


-- |
--
liftIOE :: IO a -> AppContext a
liftIOE f = liftIO (go f) >>= liftEither
  where
    go :: IO b -> IO (Either String b)
    go x = E.catchAny (Right <$> x) errHdl

    errHdl :: E.SomeException -> IO (Either String a)
    errHdl = return . Left . show

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
errorToolsCallResponse :: DM.JsonRpcRequest -> String -> AppContext ()
errorToolsCallResponse jsonRpc errStr = do
  let content = [ DM.McpToolsCallResponseResultContent "text" errStr ]
      result = DM.McpToolsCallResponseResult {
                  DM._contentMcpToolsCallResponseResult = content
                , DM._isErrorMcpToolsCallResponseResult = True
                }
      resDat = DM.McpToolsCallResponseData jsonRpc result
      res = DM.McpToolsCallResponse resDat

  resQ <- view DM.responseQueueDomainData <$> lift ask
  liftIOE $ STM.atomically $ STM.writeTQueue resQ res

-- |
--
runProc :: STM.TMVar (Maybe ProcData) -> String -> [String] -> [(String, String)] -> IO ()
runProc procVar cmd args addEnv = do

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procRunTask.runProc start."

  (fromPtyHandle, toProcHandle) <- S.createPipe
  (fromProcHandle, toPtyHandle) <- S.createPipe

  baseEnv <- Env.getEnvironment
  let cwd = Nothing
      runEnvs = Just $ baseEnv ++ addEnv

  hPutStrLn stderr $ "[INFO] env = " ++ show runEnvs
  hPutStrLn stderr $ "[INFO] cmd = " ++ cmd
  hPutStrLn stderr $ "[INFO] args = " ++ show args

  pHdl <- S.runProcess cmd args cwd runEnvs (Just fromPtyHandle) (Just toPtyHandle) (Just toPtyHandle)
  let procData = ProcData {
                  _wHdLProcData = toProcHandle
                , _rHdlProcData = fromProcHandle
                , _eHdlProcData = fromProcHandle
                , _pHdlProcData = pHdl
                }

  STM.atomically $ STM.putTMVar procVar (Just procData)

  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procRunTask.runProc end."


-- |
--   
readProc :: ProcData -> IO BS.ByteString
readProc dat = do
  let hdl = dat^.rHdlProcData
      timeoutMillis = 5000
  ready <- hWaitForInput hdl timeoutMillis
  if ready
    then BS.hGetSome hdl 1024
    else E.throwString $ "readProc: timeout waiting for input"
    