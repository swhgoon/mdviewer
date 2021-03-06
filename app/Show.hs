{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Show (runShow) where

import Prelude hiding (writeFile)

import Data.Maybe
import Data.List (elemIndex, null)

import System.FilePath
import System.Exit

import Control.Exception
import Control.Concurrent
import Control.Conditional
import Control.Monad (void) 
import Control.Monad.IO.Class

import Graphics.UI.Gtk 
import Graphics.UI.Gtk.WebKit.WebView
import Graphics.UI.Gtk.Windows.Window

import Text.Pandoc.UTF8 (writeFile)

import Types
import HtmlBuilder


offsetStyleFrom :: Int -> Command -> Styles -> Command
offsetStyleFrom offset cmd styles = cmd { style = offsetStyle }
    where stylesQueue = Nothing : map Just (listStyles styles)
          currIndex = fromJust $ elemIndex (style cmd) stylesQueue
          offsetIndex = (currIndex + offset) `mod` (length stylesQueue - 1) 
          offsetStyle = stylesQueue !! offsetIndex

nextStyleFrom :: Command -> Styles -> Command
nextStyleFrom = offsetStyleFrom 1

prevStyleFrom :: Command -> Styles -> Command
prevStyleFrom = offsetStyleFrom (-1)


setInputFile :: Command -> FilePath -> Command
setInputFile cmd path = cmd { input = path } 


setContent :: WebView -> String -> IO ()
setContent webview html = webViewLoadString webview html Nothing ""


makeTitle :: Command -> String
makeTitle cmd = status ++ "  -  Markdown Viewer" 
    where status | usesStyle cmd = input cmd ++ "@" ++ fromJust (style cmd)
                 | otherwise     = input cmd


genericDialogNew :: String -> Window -> IO FileChooserDialog
genericDialogNew action window = fileChooserDialogNew  
    (Just action) (Just window) 
    FileChooserActionSave 
    [ (action, ResponseAccept) 
    , ("Cancel", ResponseCancel) ]


saveDialogNew, openDialogNew :: Window -> IO FileChooserDialog
saveDialogNew = genericDialogNew "Save"
openDialogNew = genericDialogNew "Open"


whenReturnFilename :: FileChooserDialog -> (FilePath -> IO ()) -> IO ()
whenReturnFilename dialog action = do 
    response <- dialogRun dialog
    case response of
        ResponseAccept -> do
            dialogVal <- fileChooserGetFilename dialog
            case dialogVal of
                Just path -> action path
                _ -> return ()
        _ -> return ()


abortDialog :: Window ->  IO ()
abortDialog window = do 
    dialog <- messageDialogNew (Just window) [] MessageError ButtonsOk 
                ("An internal error happened. Aborting" :: String)
    _ <- dialogRun dialog
    widgetDestroy dialog    
    exitFailure

invalidFileDialog :: Window -> String -> IO ()
invalidFileDialog window path = do
    dialog <- messageDialogNew (Just window) [] MessageError ButtonsOk 
                ("Unable to load " ++ path)
    _ <- dialogRun dialog
    widgetDestroy dialog    


runShow :: Command -> Styles -> IO ()
runShow cmd styles = do
    
    -- Create an "global" state that keeps the style and the current file
    -- displayed between different events handles
    status <- newMVar cmd
    fullscreen <- newMVar False
    lastPos <- newEmptyMVar

    -- Initialize the GUI
    void initGUI
    
    -- Create the widgets
    window <- windowNew
    scrolled <- scrolledWindowNew Nothing Nothing
    webview <- webViewNew
    
    -- Set widgets default attributes
    window `set` [ windowTitle          := makeTitle cmd
                 , windowResizable      := True
                 , windowWindowPosition := WinPosCenter
                 , windowDefaultWidth   := 640
                 , windowDefaultHeight  := 640
                 , containerChild       := scrolled ]

    scrolled `set` [ containerChild := webview ]
    
    result <- renderContents (input cmd) (styles @> cmd)
    maybe (invalidFileDialog window (input cmd) >> exitFailure) 
          (setContent webview) result

    
    -- Handle events
    window `on` deleteEvent $ liftIO mainQuit >> return False

    window `on` keyPressEvent $ tryEvent $ do
        "F11" <- eventKeyName
        liftIO $ do 
            isFullscreen <- readMVar fullscreen
            if isFullscreen
                then do
                    modifyMVar_ fullscreen (return . not) 
                    windowUnfullscreen window
                else do
                    modifyMVar_ fullscreen (return . not) 
                    windowFullscreen window

    window `on` keyPressEvent $ tryEvent $ do
        "q" <- eventKeyName
        liftIO $ mainQuit >> exitSuccess

    window `on` keyPressEvent $ tryEvent $ do
        "r" <- eventKeyName
        liftIO $ do 
            
            uri <- webViewGetUri webview
            let isInputFile = maybe False (==[]) uri
            
            when isInputFile $ do
                adj <- scrolledWindowGetVAdjustment scrolled
                pos <- adjustmentGetValue adj 
                putMVar lastPos pos 
                

            cmd' <- readMVar status 
            result <- renderContents (input cmd') (styles @> cmd')
            maybe (abortDialog window) (setContent webview) result
    
    webview `after` loadFinished $ \_ ->  do
        liftIO $ do
            pos <- tryTakeMVar lastPos
            when (isJust pos) $ do 
                adj <- scrolledWindowGetVAdjustment scrolled
                adjustmentSetValue adj (fromJust pos)
                adjustmentValueChanged adj            
    
    window `on` keyPressEvent $ tryEvent $ do
        "j" <- eventKeyName
        liftIO $ do 
            adj <- scrolledWindowGetVAdjustment scrolled
            ps <- adjustmentGetStepIncrement adj
            pos <- adjustmentGetValue adj
            adjustmentSetValue adj (pos + ps)
            adjustmentValueChanged adj
    
    window `on` keyPressEvent $ tryEvent $ do
        "k" <- eventKeyName
        liftIO $ do 
            adj <- scrolledWindowGetVAdjustment scrolled
            ps <- adjustmentGetStepIncrement adj
            pos <- adjustmentGetValue adj
            adjustmentSetValue adj (pos - ps)
            adjustmentValueChanged adj

    window `on` keyPressEvent $ tryEvent $ do
        "g" <- eventKeyName
        liftIO $ do 
            adj <- scrolledWindowGetVAdjustment scrolled
            top <- adjustmentGetLower adj
            adjustmentSetValue adj top
            adjustmentValueChanged adj            
    
    window `on` keyPressEvent $ tryEvent $ do
        "G" <- eventKeyName
        liftIO $ do 
            adj <- scrolledWindowGetVAdjustment scrolled
            bottom <- adjustmentGetUpper adj
            adjustmentSetValue adj bottom
            adjustmentValueChanged adj            

    
    window `on` keyPressEvent $ tryEvent $ do
        "z" <- eventKeyName
        liftIO $ do 
            canGoBack <- webViewCanGoBack webview
            if canGoBack 
                then webViewGoBack webview 
                else do
                    cmd' <- readMVar status 
                    result <- renderContents (input cmd') (styles @> cmd')
                    maybe (abortDialog window) (setContent webview) result

    window `on` keyPressEvent $ tryEvent $ do
        "x" <- eventKeyName
        liftIO $ do 
            canGoForward <- webViewCanGoForward webview
            when (canGoForward) (webViewGoForward webview)


    window `on` keyPressEvent $ tryEvent $ do
        "n" <- eventKeyName
        liftIO $ do
            cmd' <- modifyMVar status $ \cmd -> do
                let cmd' = cmd `nextStyleFrom` styles 
                return (cmd', cmd')
            result <- renderContents (input cmd') (styles @> cmd')
            maybe (abortDialog window) (setContent webview) result
            window `set` [ windowTitle := makeTitle cmd' ]

    window `on` keyPressEvent $ tryEvent $ do
        "N" <- eventKeyName
        liftIO $ do
            cmd' <- modifyMVar status $ \cmd -> do
                let cmd' = cmd `prevStyleFrom` styles 
                return (cmd', cmd')
            result <- renderContents (input cmd') (styles @> cmd')
            maybe (abortDialog window) (setContent webview) result
            window `set` [ windowTitle := makeTitle cmd' ]
   
    window `on` keyPressEvent $ tryEvent $ do
        "e" <- eventKeyName
        liftIO $ do
            
            dialog <- openDialogNew window
            filter <- fileFilterNew
            fileFilterAddMimeType filter ("text/plain" :: String)
            fileChooserAddFilter dialog filter
            widgetShow dialog
            dialog `whenReturnFilename` \path -> do
                
                putStrLn $ "Opening file from " ++ path
                cmd' <- modifyMVar status $ \cmd -> do
                    let cmd' = setInputFile cmd path
                    return (cmd', cmd')
                result <- renderContents (input cmd') (styles @> cmd')
                case result of 
                    Nothing -> invalidFileDialog window path 
                    Just html' -> do 
                        webview `setContent` html'
                        window `set` [ windowTitle := makeTitle cmd' ]
            
            widgetDestroy dialog

    window `on` keyPressEvent $ tryEvent $ do
        "w" <- eventKeyName
        liftIO $ do
            
            dialog <- saveDialogNew window
            widgetShow dialog
            dialog `whenReturnFilename` \path -> do
                
                cmd' <- readMVar status
                result <- renderContents (input cmd') (styles @> cmd')
                maybe (abortDialog window) (\html' -> do
                
                    let path' = if hasExtension path
                                then path
                                else path <.> "html"
                
                    putStrLn $ "Saving html file to " ++ path'
                    writeFile path' html' 
                    ) result
            
            widgetDestroy dialog
   
    
    -- Start the GUI main loop
    widgetShowAll window
    mainGUI

