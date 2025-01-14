{-# Language CPP #-}
-- Copyright 2009-2010 Corey O'Connor
-- | Xterm output driver. This uses the Terminfo driver with some
-- extensions for Xterm.
module Graphics.Vty.Output.XTermColor
  ( reserveTerminal
  )
where

import Graphics.Vty.Output.Interface
import Graphics.Vty.Input.Mouse
import Graphics.Vty.Input.Focus
import Graphics.Vty.Attributes.Color (ColorMode)
import qualified Graphics.Vty.Output.TerminfoBased as TerminfoBased

import Blaze.ByteString.Builder (writeToByteString)
import Blaze.ByteString.Builder.Word (writeWord8)

import qualified Data.ByteString.Char8 as BS8
import Data.ByteString.Char8 (ByteString)
import Foreign.Ptr (castPtr)

import Control.Monad (void, when)
import Control.Monad.Trans
import Data.Char (toLower)
import Data.IORef

import System.Posix.IO (fdWriteBuf)
import System.Posix.Types (ByteCount, Fd)
import System.Posix.Env (getEnv)

import Data.List (isInfixOf)
import Data.Maybe (catMaybes)

#if !MIN_VERSION_base(4,11,0)
import Data.Monoid ((<>))
#endif

-- | Write a 'ByteString' to an 'Fd'.
fdWrite :: Fd -> ByteString -> IO ByteCount
fdWrite fd s =
    BS8.useAsCStringLen s $ \(buf,len) -> do
        fdWriteBuf fd (castPtr buf) (fromIntegral len)

-- | Construct an Xterm output driver. Initialize the display to UTF-8.
reserveTerminal :: ( Applicative m, MonadIO m ) => String -> Fd -> ColorMode -> m Output
reserveTerminal variant outFd colorMode = liftIO $ do
    let flushedPut = void . fdWrite outFd
    -- If the terminal variant is xterm-color use xterm instead since,
    -- more often than not, xterm-color is broken.
    let variant' = if variant == "xterm-color" then "xterm" else variant

    utf8a <- utf8Active
    when (not utf8a) $ flushedPut setUtf8CharSet
    t <- TerminfoBased.reserveTerminal variant' outFd colorMode

    mouseModeStatus <- newIORef False
    focusModeStatus <- newIORef False
    pasteModeStatus <- newIORef False

    let xtermSetMode t' m newStatus = do
          curStatus <- getModeStatus t' m
          when (newStatus /= curStatus) $
              case m of
                  Focus -> liftIO $ do
                      case newStatus of
                          True -> flushedPut requestFocusEvents
                          False -> flushedPut disableFocusEvents
                      writeIORef focusModeStatus newStatus
                  Mouse -> liftIO $ do
                      case newStatus of
                          True -> flushedPut requestMouseEvents
                          False -> flushedPut disableMouseEvents
                      writeIORef mouseModeStatus newStatus
                  BracketedPaste -> liftIO $ do
                      case newStatus of
                          True -> flushedPut enableBracketedPastes
                          False -> flushedPut disableBracketedPastes
                      writeIORef pasteModeStatus newStatus
                  Hyperlink -> setMode t Hyperlink newStatus

        xtermGetMode Mouse = liftIO $ readIORef mouseModeStatus
        xtermGetMode Focus = liftIO $ readIORef focusModeStatus
        xtermGetMode BracketedPaste = liftIO $ readIORef pasteModeStatus
        xtermGetMode Hyperlink = getModeStatus t Hyperlink

    let t' = t
             { terminalID = terminalID t ++ " (xterm-color)"
             , releaseTerminal = do
                 when (not utf8a) $ liftIO $ flushedPut setDefaultCharSet
                 setMode t' BracketedPaste False
                 setMode t' Mouse False
                 setMode t' Focus False
                 releaseTerminal t
             , mkDisplayContext = \tActual r -> do
                dc <- mkDisplayContext t tActual r
                return $ dc { inlineHack = xtermInlineHack t' }
             , supportsMode = const True
             , getModeStatus = xtermGetMode
             , setMode = xtermSetMode t'
             }
    return t'

utf8Active :: IO Bool
utf8Active = do
    let vars = ["LC_ALL", "LANG", "LC_CTYPE"]
    results <- map (toLower <$>) . catMaybes <$> mapM getEnv vars
    let matches = filter ("utf8" `isInfixOf`) results <>
                  filter ("utf-8" `isInfixOf`) results
    return $ not $ null matches

-- | Enable bracketed paste mode:
-- http://cirw.in/blog/bracketed-paste
enableBracketedPastes :: ByteString
enableBracketedPastes = BS8.pack "\ESC[?2004h"

-- | Disable bracketed paste mode:
disableBracketedPastes :: ByteString
disableBracketedPastes = BS8.pack "\ESC[?2004l"

-- | These sequences set xterm based terminals to UTF-8 output.
--
-- There is no known terminfo capability equivalent to this.
setUtf8CharSet, setDefaultCharSet :: ByteString
setUtf8CharSet = BS8.pack "\ESC%G"
setDefaultCharSet = BS8.pack "\ESC%@"

xtermInlineHack :: Output -> IO ()
xtermInlineHack t = do
    let writeReset = foldMap (writeWord8.toEnum.fromEnum) "\ESC[K"
    outputByteBuffer t $ writeToByteString writeReset
