{-# LANGUAGE FlexibleContexts, FlexibleInstances, MultiParamTypeClasses, TypeFamilies, TypeSynonymInstances, OverloadedStrings #-}
module Clckwrks.Media.Monad where

import Clckwrks            (ClckT(..), ClckFormT, ClckState(..), ClckURL(..), mapClckT)
import Clckwrks.Acid
import Clckwrks.IOThread   (IOThread(..), startIOThread, killIOThread)
import Clckwrks.Media.Acid
import Clckwrks.Media.Preview
import Clckwrks.Media.PreProcess (mediaCmd)
import Clckwrks.Media.Types
import Clckwrks.Media.URL
import Control.Applicative ((<$>))
import Control.Exception   (bracket)
import Control.Monad.Reader (ReaderT(..), MonadReader(..))
import Data.Acid           (AcidState)
import Data.Acid.Local     (createCheckpointAndClose, openLocalStateFrom)
import qualified Data.Map  as Map
import Data.Maybe          (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Happstack.Server
import Happstack.Server.Internal.Monads (FilterFun)
import HSP.XML              (Attribute(MkAttr), XML(..), pAttrVal)
import HSP.XMLGenerator     (Attr((:=)), EmbedAsAttr(..), EmbedAsChild(..), IsName(toName))
import Magic                (Magic, MagicFlag(..), magicLoadDefault, magicOpen)
import System.Directory     (createDirectoryIfMissing)
import System.FilePath      ((</>))
import Text.Reform          (CommonFormError, FormError(..))
import Web.Routes           (showURL)

data MediaConfig = MediaConfig
    { mediaDirectory :: FilePath -- ^ directory in which to store uploaded media files
    , mediaState     :: AcidState MediaState
    , mediaMagic     :: Magic
    , mediaIOThread  :: IOThread (Medium, PreviewSize) FilePath
    , mediaClckURL   :: ClckURL -> [(T.Text, Maybe T.Text)] -> T.Text
    }

type MediaT m = ClckT MediaURL (ReaderT MediaConfig m)
type MediaM = ClckT MediaURL (ReaderT MediaConfig (ServerPartT IO))

data MediaFormError
    = MediaCFE (CommonFormError [Input])
      deriving Show

instance FormError MediaFormError where
    type ErrorInputType MediaFormError = [Input]
    commonFormError = MediaCFE

instance (Functor m, Monad m) => EmbedAsChild (MediaT m) MediaFormError where
    asChild e = asChild (show e)

type MediaForm = ClckFormT MediaFormError MediaM

instance (IsName n TL.Text) => EmbedAsAttr MediaM (Attr n MediaURL) where
        asAttr (n := u) =
            do url <- showURL u
               asAttr $ MkAttr (toName n, pAttrVal (TL.fromStrict url))

instance (IsName n TL.Text) => EmbedAsAttr MediaM (Attr n ClckURL) where
        asAttr (n := url) =
            do showFn <- mediaClckURL <$> ask
               asAttr $ MkAttr (toName n, pAttrVal (TL.fromStrict $ showFn url []))

runMediaT :: MediaConfig -> MediaT m a -> ClckT MediaURL m a
runMediaT mc m = mapClckT f m
    where
      f r = runReaderT r mc

instance (Monad m) => MonadReader MediaConfig (MediaT m) where
    ask = ClckT $ ask
    local f (ClckT m) = ClckT $ local f m

instance (Functor m, Monad m) => GetAcidState (MediaT m) MediaState where
    getAcidState =
        mediaState <$> ask

withMediaConfig :: Maybe FilePath -> FilePath -> (MediaConfig -> IO a) -> IO a
withMediaConfig mBasePath mediaDir f =
    do let basePath = fromMaybe "_state" mBasePath
           cacheDir  = mediaDir </> "_cache"
       createDirectoryIfMissing True cacheDir
       bracket (openLocalStateFrom (basePath </> "media") initialMediaState) (createCheckpointAndClose) $ \media ->
         bracket (startIOThread (applyTransforms mediaDir cacheDir)) killIOThread $ \ioThread ->
           do magic <- magicOpen [MagicMime, MagicError]
              magicLoadDefault magic
              f (MediaConfig { mediaDirectory = mediaDir
                             , mediaState     = media
                             , mediaMagic     = magic
                             , mediaIOThread  = ioThread
                             , mediaClckURL   = undefined
                             })
