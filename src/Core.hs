{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-missing-methods #-}

module Core where








import Agda.Interaction.Base (Command, Command' (Command, Done, Error), CommandState (optionsOnReload), IOTCM, Interaction (..), initCommandState, CommandM)
import qualified Agda.Interaction.Imports as Imp
import Agda.Interaction.InteractionTop (handleCommand_, initialiseCommandQueue, runInteraction, maybeAbort)
import Agda.Interaction.Options (CommandLineOptions (optAbsoluteIncludePaths))
import Agda.Interaction.Response (Response (..))
import Agda.TypeChecking.Errors (prettyError, prettyTCWarnings')
import Agda.TypeChecking.Monad
  ( TCErr,
    commandLineOptions,
    runTCMTop',
  )
import Agda.TypeChecking.Monad.Base (TCM)
import Agda.TypeChecking.Monad.State (setInteractionOutputCallback)
import Agda.Utils.Impossible (CatchImpossible (catchImpossible), Impossible)
import Agda.Utils.Pretty (pretty, render)
import Agda.VersionCommit (versionWithCommitInfo)
import Common
import Control.Concurrent
import Control.Exception
import Control.Monad.Except (catchError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader
import Control.Monad.State
import Data.Maybe (listToMaybe)
import Data.Text (pack)
import Lispify (lispifyResponse)
import qualified Agda.TypeChecking.Monad.Benchmark as Bench

getAgdaVersion :: String
getAgdaVersion = versionWithCommitInfo

-- instance Show Response where
-- instance Show CommandState where

interact :: ServerM ()
interact = do
  env <- ask

  result <- runTCMPrettyErrors $ do
      -- decides how to output Response
    lift $ setInteractionOutputCallback $ \response -> do
        -- let message = case response of
        --       Resp_HighlightingInfo {} -> "Resp_HighlightingInfo"
        --       Resp_Status {} -> "Resp_Status"
        --       Resp_JumpToError {} -> "Resp_JumpToError"
        --       Resp_InteractionPoints {} -> "Resp_InteractionPoints"
        --       Resp_GiveAction {} -> "Resp_GiveAction"
        --       Resp_MakeCase {} -> "Resp_MakeCase"
        --       Resp_SolveAll {} -> "Resp_SolveAll"
        --       Resp_DisplayInfo {} -> "Resp_DisplayInfo"
        --       Resp_RunningInfo {} -> "Resp_RunningInfo"
        --       Resp_ClearRunningInfo {} -> "Resp_ClearRunningInfo"
        --       Resp_ClearHighlighting {} -> "Resp_ClearHighlighting"
        --       Resp_DoneAborting {} -> "Resp_DoneAborting"
        --       Resp_DoneExiting {} -> "Resp_DoneExiting"
        lispified <- lispifyResponse response
        signalResponse env response

    -- keep reading command
    commands <- liftIO $ initialiseCommandQueue (readCommand env)

    -- start the loop     
    opts <- commandLineOptions
    let commandState = (initCommandState commands) { optionsOnReload = opts { optAbsoluteIncludePaths = [] } }
    mapReaderT (`runStateT` commandState) loop

    return ""

  case result of
    Left err -> return ()
    Right val -> return ()
  where

    loop :: ServerM' CommandM ()
    loop = do
      Bench.reset
      done <- Bench.billTo [] $ do
        r <- lift $ maybeAbort runInteraction
        case r of
          Done      -> return True -- Done.
          Error s   -> do
            writeLog ("Error " <> pack s)
            return False
          Command _ -> do
            signalCommandDone 
            return False

      lift Bench.print
      unless done loop

    -- Reads the next command from the Channel
    readCommand :: Env -> IO Command
    readCommand env = Command <$> readChan (envCommandChan env)

parseIOTCM :: String -> Either String IOTCM
parseIOTCM raw = case listToMaybe $ reads raw of
  Just (x, "") -> Right x
  Just (_, rem) -> Left $ "not consumed: " ++ rem
  _ -> Left $ "cannot read: " ++ raw
  
-- TODO: handle the caught errors
-- | Run a TCM action in IO and throw away all of the errors
runTCMPrettyErrors :: ServerM' TCM String -> ServerM' IO (Either String String)
runTCMPrettyErrors program = mapReaderT f program
  where
    f :: TCM String -> IO (Either String String)
    f program = runTCMTop' ((Right <$> program) `catchError` handleTCErr `catchImpossible` handleImpossible) `catch` catchException

    handleTCErr :: TCErr -> TCM (Either String String)
    handleTCErr err = do
      s2s <- prettyTCWarnings' =<< Imp.getAllWarningsOfTCErr err
      s1 <- prettyError err
      let ss = filter (not . null) $ s2s ++ [s1]
      let errorMsg = unlines ss
      return (Left errorMsg)

    handleImpossible :: Impossible -> TCM (Either String String)
    handleImpossible = return . Left . show

    catchException :: SomeException -> IO (Either String String)
    catchException e = return $ Left $ show e