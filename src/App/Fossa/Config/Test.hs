{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE RecordWildCards #-}

module App.Fossa.Config.Test (
  TestCliOpts,
  TestConfig (..),
  DiffRevision (..),
  TestOutputFormat (..),
  mkSubCommand,
  parser,
  loadConfig,
  validateOutputFormat,
  testOutputFormatList,
  defaultOutputFmt,
  parseFossaTestOutputFormat,
) where

import App.Fossa.Config.Common (
  CacheAction (ReadOnly),
  CommonOpts (..),
  baseDirArg,
  collectApiOpts,
  collectBaseDir,
  collectRevisionData',
  commonOpts,
  defaultTimeoutDuration,
 )
import App.Fossa.Config.ConfigFile (ConfigFile, resolveConfigFile)
import App.Fossa.Config.EnvironmentVars (EnvVars)
import App.Fossa.Subcommand (EffStack, GetCommonOpts (getCommonOpts), GetSeverity (getSeverity), SubCommand (SubCommand))
import App.Types (BaseDir, OverrideProject (OverrideProject), ProjectRevision)
import Control.Effect.Diagnostics (
  Diagnostics,
  Has,
  ToDiagnostic,
  fromMaybe,
 )
import Control.Effect.Lift (Lift)
import Control.Monad (when)
import Control.Timeout (Duration (..))
import Data.Aeson (ToJSON (toEncoding), defaultOptions, genericToEncoding)
import Data.List (intercalate)
import Data.String.Conversion (toText)
import Data.Text (Text)
import Diag.Diagnostic (ToDiagnostic (renderDiagnostic))
import Effect.Exec (Exec)
import Effect.Logger (Logger, Pretty (pretty), Severity (SevDebug, SevInfo), logWarn, vsep)
import Effect.ReadFS (ReadFS, getCurrentDir, resolveDir)
import Fossa.API.Types (ApiOpts)
import GHC.Generics (Generic)
import Options.Applicative (
  InfoMod,
  Parser,
  auto,
  flag,
  help,
  internal,
  long,
  option,
  optional,
  progDesc,
  strOption,
 )

data TestOutputFormat
  = TestOutputPretty
  | TestOutputJson
  deriving (Eq, Ord, Generic, Enum, Bounded)

instance Show TestOutputFormat where
  show TestOutputJson = "json"
  show TestOutputPretty = "text-pretty"

defaultOutputFmt :: TestOutputFormat
defaultOutputFmt = TestOutputPretty

testOutputFormatList :: String
testOutputFormatList = intercalate ", " $ map show allFormats
  where
    allFormats :: [TestOutputFormat]
    allFormats = enumFromTo minBound maxBound

newtype InvalidReportFormat = InvalidReportFormat String
instance ToDiagnostic InvalidReportFormat where
  renderDiagnostic (InvalidReportFormat fmt) =
    pretty $
      "Fossa test format "
        <> toText fmt
        <> " is not supported. Supported formats: "
        <> (toText testOutputFormatList)

validateOutputFormat :: Has Diagnostics sig m => Bool -> Maybe String -> m TestOutputFormat
validateOutputFormat True _ = pure TestOutputJson
validateOutputFormat False Nothing = pure defaultOutputFmt
validateOutputFormat False (Just format) = fromMaybe (InvalidReportFormat format) $ parseFossaTestOutputFormat format

parseFossaTestOutputFormat :: String -> Maybe TestOutputFormat
parseFossaTestOutputFormat "json" = Just TestOutputJson
parseFossaTestOutputFormat _ = Nothing

instance ToJSON TestOutputFormat where
  toEncoding = genericToEncoding defaultOptions

newtype DiffRevision = DiffRevision Text deriving (Show, Eq, Ord, Generic)

instance ToJSON DiffRevision where
  toEncoding = genericToEncoding defaultOptions

data TestCliOpts = TestCliOpts
  { commons :: CommonOpts
  , testTimeout :: Maybe Int
  , testDeprecatedOutputType :: TestOutputFormat
  , testOutputFmt :: Maybe String
  , testBaseDir :: FilePath
  , testDiffRevision :: Maybe Text
  }
  deriving (Eq, Ord, Show)

instance GetSeverity TestCliOpts where
  getSeverity TestCliOpts{commons = CommonOpts{optDebug}} = if optDebug then SevDebug else SevInfo

instance GetCommonOpts TestCliOpts where
  getCommonOpts TestCliOpts{commons} = Just commons

data TestConfig = TestConfig
  { baseDir :: BaseDir
  , apiOpts :: ApiOpts
  , timeout :: Duration
  , outputFormat :: TestOutputFormat
  , projectRevision :: ProjectRevision
  , diffRevision :: Maybe DiffRevision
  }
  deriving (Show, Generic)

instance ToJSON TestConfig where
  toEncoding = genericToEncoding defaultOptions

testInfo :: InfoMod a
testInfo = progDesc "Check for issues from FOSSA and exit non-zero when issues are found"

mkSubCommand :: (TestConfig -> EffStack ()) -> SubCommand TestCliOpts TestConfig
mkSubCommand = SubCommand "test" testInfo parser loadConfig mergeOpts

parser :: Parser TestCliOpts
parser =
  TestCliOpts
    <$> commonOpts
    <*> optional (option auto (long "timeout" <> help "Duration to wait for build completion in seconds (Defaults to 1 hour)"))
    <*> flag defaultOutputFmt TestOutputJson (long "json" <> help "Output issues as json" <> internal)
    <*> optional (strOption (long "format" <> help ("Output the report in the specified format. Currently available formats: (" <> testOutputFormatList <> ")")))
    <*> baseDirArg
    <*> optional (strOption (long "diff" <> help "Checks for new issues of the revision, that does not exist in provided diff revision."))

loadConfig ::
  ( Has (Lift IO) sig m
  , Has Diagnostics sig m
  , Has ReadFS sig m
  , Has Logger sig m
  ) =>
  TestCliOpts ->
  m (Maybe ConfigFile)
loadConfig TestCliOpts{commons = CommonOpts{optConfig}, testBaseDir} = do
  cwd <- getCurrentDir
  configBaseDir <- resolveDir cwd (toText testBaseDir)
  resolveConfigFile configBaseDir optConfig

mergeOpts ::
  ( Has (Lift IO) sig m
  , Has Diagnostics sig m
  , Has ReadFS sig m
  , Has Exec sig m
  , Has Logger sig m
  ) =>
  Maybe ConfigFile ->
  EnvVars ->
  TestCliOpts ->
  m TestConfig
mergeOpts maybeConfig envvars TestCliOpts{..} = do
  let baseDir = collectBaseDir testBaseDir
      apiOpts = collectApiOpts maybeConfig envvars commons
      timeout = maybe defaultTimeoutDuration Seconds testTimeout
      revision =
        collectRevisionData' baseDir maybeConfig ReadOnly $
          OverrideProject (optProjectName commons) (optProjectRevision commons) Nothing
      diffRevision = DiffRevision <$> testDiffRevision

  -- if the non-default value is present for flag, user is using deprecatedJsonFlag
  when (testDeprecatedOutputType /= defaultOutputFmt) $ do
    logWarn $
      vsep
        [ "DEPRECATION NOTICE"
        , "========================"
        , "--json flag is now deprecated for `fossa test` command."
        , ""
        , "Please use: "
        , "   `--format json` instead."
        , ""
        , "In future, usage of --json may result in fatal error."
        ]

  testOutputFormat <-
    validateOutputFormat
      (testDeprecatedOutputType == TestOutputJson)
      testOutputFmt

  TestConfig
    <$> baseDir
    <*> apiOpts
    <*> pure timeout
    <*> pure testOutputFormat
    <*> revision
    <*> pure diffRevision
