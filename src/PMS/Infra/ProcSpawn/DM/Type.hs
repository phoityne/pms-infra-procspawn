{-# LANGUAGE TemplateHaskell #-}

module PMS.Infra.ProcSpawn.DM.Type where

import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Except
import Control.Lens
import Data.Default
import Data.Aeson.TH
import qualified Control.Concurrent.STM as STM
import qualified System.Process as S
import qualified GHC.IO.Handle as S

import qualified PMS.Domain.Model.DM.Type as DM
import qualified PMS.Domain.Model.DM.TH as DM

-- |
--
data ProcData = ProcData {
    _wHdLProcData :: S.Handle
  , _rHdlProcData :: S.Handle
  , _eHdlProcData :: S.Handle
  , _pHdlProcData :: S.ProcessHandle
  }

makeLenses ''ProcData

-- |
--
data AppData = AppData {
               _processAppData :: STM.TMVar (Maybe ProcData)
             , _lockAppData :: STM.TMVar ()
             , _jsonrpcAppData :: DM.JsonRpcRequest
             }

makeLenses ''AppData

defaultAppData :: IO AppData
defaultAppData = do
  mgrVar <- STM.newTMVarIO Nothing
  lock    <- STM.newTMVarIO ()
  return AppData {
           _processAppData = mgrVar
         , _lockAppData = lock
         , _jsonrpcAppData = def
         }

-- |
--
type AppContext = ReaderT AppData (ReaderT DM.DomainData (ExceptT DM.ErrorData (LoggingT IO)))

-- |
--
type IOTask = IO


--------------------------------------------------------------------------------------------
-- |
--
data ProcStringToolParams =
  ProcStringToolParams {
    _argumentsProcStringToolParams :: String
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "ProcStringToolParams", omitNothingFields = True} ''ProcStringToolParams)
makeLenses ''ProcStringToolParams

instance Default ProcStringToolParams where
  def = ProcStringToolParams {
        _argumentsProcStringToolParams = def
      }


-- |
--
data ProcCommandToolParams =
  ProcCommandToolParams {
    _commandProcCommandToolParams   :: String
  , _argumentsProcCommandToolParams :: Maybe [String]
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "ProcCommandToolParams", omitNothingFields = True} ''ProcCommandToolParams)
makeLenses ''ProcCommandToolParams

instance Default ProcCommandToolParams where
  def = ProcCommandToolParams {
        _commandProcCommandToolParams   = def
      , _argumentsProcCommandToolParams = def
      }

-- |
--
data ProcStringArrayToolParams =
  ProcStringArrayToolParams {
    _argumentsProcStringArrayToolParams :: [String]
  } deriving (Show, Read, Eq)

$(deriveJSON defaultOptions {fieldLabelModifier = DM.dropDataName "ProcStringArrayToolParams", omitNothingFields = True} ''ProcStringArrayToolParams)
makeLenses ''ProcStringArrayToolParams

instance Default ProcStringArrayToolParams where
  def = ProcStringArrayToolParams {
        _argumentsProcStringArrayToolParams = def
      }
