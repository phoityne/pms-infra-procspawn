{-# LANGUAGE OverloadedStrings #-}

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
-- import qualified System.IO as S
-- import qualified System.Environment as S
import qualified Data.ByteString as BS

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

-- |
--
runProc :: STM.TMVar (Maybe ProcData) -> String -> [String]-> IO ()
runProc procVar cmd args = do
  hPutStrLn stderr "[INFO] PMS.Infra.ProcSpawn.DS.Core.procRunTask.runProc start."
  (fromPmsHandle, toProcHandle) <- S.createPipe
  (fromProcHandle, toPmsHandle) <- S.createPipe
  let cwd = Nothing
      runEnvs = Nothing

--  osEnc <- mkTextEncoding "UTF-8//TRANSLIT"
--  S.hSetEncoding toPmsHandle osEnc
--  S.hSetEncoding fromPmsHandle S.utf8
--  S.hSetEncoding toProcHandle S.utf8
--  S.hSetEncoding fromProcHandle osEnc

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



-- |
--   
readProc :: ProcData -> IO BS.ByteString
readProc dat = do
  let hdl = dat^.rHdlProcData
  BS.hGetSome hdl 4096
