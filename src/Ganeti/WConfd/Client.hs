{-# LANGUAGE TemplateHaskell, FlexibleContexts #-}

{-| The Ganeti WConfd client functions.

The client functions are automatically generated from Ganeti.WConfd.Core

-}

{-

Copyright (C) 2014 Google Inc.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-}

module Ganeti.WConfd.Client where

import Control.Concurrent (threadDelay)
import Control.Exception.Lifted (bracket)
import Control.Monad (unless)
import Control.Monad.Base
import Control.Monad.Error (MonadError)
import Control.Monad.Trans.Control (MonadBaseControl)

import Ganeti.BasicTypes (runResultT, GenericResult(..))
import Ganeti.Constants
import Ganeti.Errors (GanetiException)
import Ganeti.JSON (unMaybeForJSON)
import Ganeti.Locking.Locks (ClientId)
import Ganeti.Objects (ConfigData)
import qualified Ganeti.Path as Path
import Ganeti.THH.HsRPC
import Ganeti.UDSServer (ConnectConfig(..), Client, connectClient, closeClient)
import Ganeti.WConfd.Core (exportedFunctions)

-- * Generated client functions

$(mkRpcCalls exportedFunctions)

-- * Helper functions for creating the client

-- | The default WConfd client configuration
wconfdConnectConfig :: ConnectConfig
wconfdConnectConfig = ConnectConfig { recvTmo    = wconfdDefRwto
                                    , sendTmo    = wconfdDefRwto
                                    }

-- | Given a socket path, creates a WConfd client with the default
-- configuration and timeout.
getWConfdClient :: FilePath -> IO Client
getWConfdClient = connectClient wconfdConnectConfig wconfdDefCtmo

-- | Run an Rpc with a fresh client.
runNewWConfdClient :: ( MonadBase IO m, MonadBaseControl IO m
                      ,  MonadError GanetiException m )
                   => RpcClientMonad a -> m a
runNewWConfdClient request =
  bracket (liftBase (Path.defaultWConfdSocket >>= getWConfdClient))
          (liftBase . closeClient)
    $ runRpcClient request

-- * Helper functions for getting a remote lock

-- | Calls the `lockConfig` RPC until the lock is obtained.
waitLockConfig :: ClientId
               -> Bool  -- ^ whether the lock shall be in shared mode
               -> RpcClientMonad ConfigData
waitLockConfig c shared = do
  mConfigData <- lockConfig c shared
  case unMaybeForJSON mConfigData of
    Just configData -> return configData
    Nothing         -> waitLockConfig c shared

-- | Calls the `lockConfig` RPC until the lock is obtained,
-- runs a function on the obtained config, and calls `unlockConfig`.
withLockedConfig :: ClientId
                 -> Bool  -- ^ whether the lock shall be in shared mode
                 -> (ConfigData -> RpcClientMonad a)  -- ^ action to run
                 -> RpcClientMonad a
withLockedConfig c shared =
  -- Unlock config even if something throws.
  bracket (waitLockConfig c shared) (const $ unlockConfig c)


-- * Other functions

-- | Try an RPC until no errors occur and the result is true.
runModifyRpc :: RpcClientMonad Bool -> IO ()
runModifyRpc action = do
  res <- runResultT $ runNewWConfdClient action
  unless (res == Ok True) $ do
    threadDelay 100000 -- sleep 0.1 seconds
    runModifyRpc action
