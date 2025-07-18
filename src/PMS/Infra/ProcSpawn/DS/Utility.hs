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
   BS.hGetSome hdl 1024
{-
  out <- BS.hGetNonBlocking (dat^.rHdlProcData) 1024
  err <- BS.hGetNonBlocking (dat^.eHdlProcData) 1024
  let combined = out <> err
  let text = TE.decodeUtf8With (\_ _ -> Just '?') combined
  hPutStrLn stderr $ "[DEBUG readProc] received: " ++ T.unpack text
  return combined
-}
{-
  S.hSetBuffering fromPtyHandle NoBuffering
  S.hSetBuffering toPtyHandle   NoBuffering
  S.hSetBuffering fromProcHandle NoBuffering
  S.hSetBuffering toProcHandle   NoBuffering
  S.hSetBuffering fromProcEHandle NoBuffering
  S.hSetBuffering toPtyEHandle   NoBuffering


  mp <- findExecutable "ssh"
  hPutStrLn stderr $ "[INFO] findExecutable = " ++ show mp

  let pathKey = "PATH"
      openSSH = "C:\\Windows\\System32\\OpenSSH"
      updatedEnv = case lookup pathKey baseEnv of
        Just oldPath -> (pathKey, openSSH ++ ";" ++ oldPath) : filter ((/= pathKey) . fst) baseEnv
        Nothing      -> (pathKey, openSSH) : baseEnv

  hPutStrLn stderr $ "[INFO] updatedEnv = " ++ show updatedEnv
-}

{-
  S.hSetBuffering fromPtyHandle NoBuffering
  S.hSetBuffering toPtyHandle   NoBuffering
  S.hSetBuffering fromProcHandle NoBuffering
  S.hSetBuffering toProcHandle   NoBuffering

  osEnc <- mkTextEncoding "UTF-8//TRANSLIT"
  S.hSetEncoding toPtyHandle osEnc
  S.hSetEncoding fromPtyHandle S.utf8
  S.hSetEncoding toProcHandle S.utf8
  S.hSetEncoding fromProcHandle osEnc
-}
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
{-
envall :: [(String, String)]
envall =
  [ ("Path", "C:\\Windows\\system32;C:\\Windows;C:\\Windows\\System32\\Wbem;C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\;C:\\Windows\\System32\\OpenSSH\\;C:\\Program Files\\dotnet\\;C:\\Program Files (x86)\\NVIDIA Corporation\\PhysX\\Common;C:\\Program Files\\NVIDIA Corporation\\NVIDIA app\\NvDLISR;C:\\Program Files\\Git\\cmd;C:\\Program Files\\TortoiseGit\\bin;C:\\Program Files (x86)\\Windows Kits\\10\\Windows Performance Toolkit\\;C:\\Users\\phoityne\\AppData\\Local\\Microsoft\\WindowsApps;C:\\Users\\phoityne\\AppData\\Local\\Programs\\Microsoft VS Code\\bin;C:\\ghcup\\bin;C:\\Users\\phoityne\\.dotnet\\tools;c:\\tools\\ghcup\\bin;C:\\Users\\phoityne\\AppData\\Local\\Programs\\Microsoft VS Code Insiders\\bin;c:\\tools\\cabal\\bin;;C:\\Users\\phoityne\\.lmstudio\\bin")
--  , ("PATHEXT", ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC")
--  , ("PROCESSOR_ARCHITECTURE", "AMD64")
--  , ("PROCESSOR_IDENTIFIER", "Intel64 Family 6 Model 183 Stepping 1, GenuineIntel")
--  , ("PROCESSOR_LEVEL", "6")
--  , ("PROCESSOR_REVISION", "b701")
  , ("ProgramData", "C:\\ProgramData")  -- required for ssh.
-------  , ("ProgramFiles", "C:\\Program Files")
-------    , ("ProgramFiles(x86)", "C:\\Program Files (x86)")
-------    , ("ProgramW6432", "C:\\Program Files")
--  , ("PROMPT", "$P$G")
-------      , ("PSModulePath", "C:\\Program Files\\WindowsPowerShell\\Modules;C:\\Windows\\system32\\WindowsPowerShell\\v1.0\\Modules")
--  , ("PUBLIC", "C:\\Users\\Public")
--  , ("SESSIONNAME", "Console")
------  , ("SystemDrive", "C:")
  , ("SystemRoot", "C:\\Windows")  -- required for ssh.
------  , ("TEMP", "C:\\Users\\phoityne\\AppData\\Local\\Temp")
------  , ("TMP", "C:\\Users\\phoityne\\AppData\\Local\\Temp")
------  , ("USERDOMAIN", "GameNote")
------  , ("USERDOMAIN_ROAMINGPROFILE", "GameNote")
------  , ("USERNAME", "phoityne")
------  , ("USERPROFILE", "C:\\Users\\phoityne")
------  , ("windir", "C:\\Windows")
--  , ("ZES_ENABLE_SYSMAN", "1")
  ]
  -}
  