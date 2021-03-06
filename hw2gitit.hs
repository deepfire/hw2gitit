{-# LANGUAGE ScopedTypeVariables #-}
-- hw2gitit.hs
-- Creates a git repository 'wiki' containing markdown versions of all
-- the pages in haskellwiki.
-- Individual HTML pages and images are cached in cache/.
-- Cache should be deleted for a fresh download.

import Codec.Digest.SHA
import Data.Ord (comparing)
import Text.Printf (printf)
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Lazy.Char8 as BC
import Prelude hiding (catch)
import Control.Exception (catch)
import Network.URI
import Network.HTTP hiding (Header)
import Control.Monad
import Data.Char (isDigit)
import Data.List
import Text.HTML.TagSoup
import Data.FileStore
import Codec.Binary.UTF8.String
import Text.Printf
import Text.Pandoc
import Text.Pandoc.Shared (stringify)
import System.Environment
import System.Directory
import System.FilePath
import Data.IORef
import System.IO.Unsafe
import Network.HTTP.Conduit
import System.IO

data Version = Version { vId :: Integer
                       , vUser :: String
                       , vDate :: String
                       , vDescription :: String } deriving (Show)

cache :: FilePath
cache = "cache"

wiki :: FilePath
wiki = "wiki"

wikiHostWWW :: String
wikiHostWWW = "https://www.nixos.org"
wikiHostNoWWW :: String
wikiHostNoWWW = "https://nixos.org"
wikiHost :: String
wikiHost = wikiHostNoWWW

wPrefix :: String
wPrefix = "/w"
wikiPrefix :: String
wikiPrefix = "/wiki"

-- a local list of resources that have been included,
-- to speed things up
resources :: IORef [String]
resources = unsafePerformIO $ newIORef []

main :: IO ()
main = do
  -- Create filestore in 'wiki' directory, unless it exists
  let fs = gitFileStore wiki
  exists <- doesDirectoryExist wiki
  unless exists $ initialize fs
  pages <- (nub . concat) `fmap` mapM getIndex indices
  ind <- index fs
  let pagepairs = sort
        [(fromUrl p,p) | p <- pages, (fromUrl p ++ ".page") `notElem` ind]
  -- Add all pages to the repository, except those already there
  printf "; total of %d pages\n" (length pagepairs)
  mapM_ (doPage fs) pagepairs

openURL :: String -> IO String
openURL x = do
  byst <- simpleHttp x
  return $ BC.unpack byst

tr :: Char -> Char -> String -> String
tr c1 c2 = map (\c -> if c == c1 then c2 else c)

openURL' :: String -> IO String
openURL' url = do
  let cachename = cache ++ "/" ++ (showBSasHex $ hash SHA256 $ BC.pack url)
  createDirectoryIfMissing True cache
  cached <- doesFileExist cachename
  printf "; ..trying %s.. " url
  hFlush stdout
  src <- if cached then
            readFile cachename
          else
            openURL url
  printf "len %d%s\n" (length src) (if cached then " (cached)" else "")
  unless cached $ writeFile cachename src
  return src

indices :: [String]
indices =  [ wikiHost ++ wikiPrefix ++ "/Special:Allpages/%24"
           , wikiHost ++ wikiPrefix ++ "/Special:Allpages/G"
           , wikiHost ++ wikiPrefix ++ "/Special:Allpages/L"
           , wikiHost ++ wikiPrefix ++ "/Special:Allpages/U"
           ]

-- get list of pages listed on index URL
getIndex :: String -> IO [String]
getIndex url = do
  putStrLn $ "Fetching index of pages: " ++ url
  src <- openURL' url
  let tags = parseTags $ decodeString src
  return $ getPageNames tags

stripPref :: String -> String -> String
stripPref pref s = maybe s id $ stripPrefix pref s

strip :: String -> String
strip = reverse . dropWhile (==' ') . reverse . dropWhile (==' ')

-- parse index page and return list of URLs for pages
getPageNames :: [Tag String] -> [String]
getPageNames [] = []
getPageNames (t@(TagOpen "a" _) : ts) =
  case fromAttrib "href" t of
       x | (wikiPrefix ++ "/index.php?title=") `isPrefixOf` x -> getPageNames ts
         | (wikiPrefix ++ "/") `isPrefixOf` x ->
                stripPref (wikiPrefix ++ "/") x : getPageNames ts
         | otherwise -> getPageNames ts
getPageNames (t:ts) = getPageNames ts

-- convert URL to page name
fromUrl :: String -> String
fromUrl = fromUrlString . decodeString . unEscapeString . takeWhile (/='?')

-- filestore can't deal with ? and * in filenames
fromUrlString :: String -> String
fromUrlString =
  unwords . words . strip . filter (\c -> c /='?' && c /='*') . ulToSpace

removeDoubleDots :: String -> String
removeDoubleDots ('.':'.':xs) = removeDoubleDots ('.':xs)
removeDoubleDots ['.'] = []
removeDoubleDots (x:xs) = x:removeDoubleDots xs
removeDoubleDots [] = []

toVersion :: [Tag String] -> Version
toVersion ts =
  Version{ vId = read id', vUser = auth, vDate = date, vDescription = desc }
    where id' = case rs of
                   (t:_) -> case fromAttrib "value" t of
                                  "" -> case as of
                                          ((t:_):_) -> reverse $ takeWhile isDigit
                                                       $ reverse $ fromAttrib "href" t
                                  x  -> x
                   _     -> error "toVersion, empty rs list"
          rs = case dropWhile (~/= TagOpen "input" [("type","radio")]) ts of
                    [] -> ts  -- to handle pages with just one commit
                    xs -> xs
          auth = case as of
                      (_:(_:TagText x:_):_) -> x
                      _ -> "hw2gitit"
          date = case as of
                      ((_:TagText x:_):_) -> x
                      _ -> ""
          desc = case dropWhile (~/= TagOpen "span" [("class","comment")]) ts of
                        (_:TagText x:_) -> reverse $ drop 1 $ reverse $ drop 1 x
                        _ -> ""
          as = partitions (~== TagOpen "a" []) rs

-- get the page from the web or cache, convert it to markdown and
-- add it to the repository.
doPage :: FileStore -> (String,String) -> IO ()
doPage fs (page',page) = do
  let pageHistoryUrl = wikiHost ++ wPrefix ++ "/index.php?title=" ++ page ++ "&limit=500&action=history"
  src <- openURL' $ pageHistoryUrl
  let tags = takeWhile (~/= TagClose "ul")
           $ dropWhile (~/= TagOpen "ul" [("id","pagehistory")])
           $ parseTags $ decodeString src
  let lis = partitions (~== TagOpen "li" []) tags
  let versions = sortBy (comparing vId) $ map toVersion lis
  -- let versions = [ Version {vId=1308, vUser="Ashley Y",vDate="23:54, 4 January 2006",vDescription = "Initial commit"}
  mapM_ (doPageVersion fs (page',page)) versions

doPageVersion :: FileStore -> (String,String) -> Version -> IO ()
doPageVersion fs (page',page) version = do
  let fname = page' ++ ".page"
  -- first, check mediawiki source to make sure it's not a redirect page
      pageVersionIndexUrl = wikiHost ++ wPrefix ++ "/index.php?title=" ++ page ++ "&action=edit"
  mwsrc <- openURL' pageVersionIndexUrl
  let redir = case (drop 1 $ dropWhile (~/= TagOpen "textarea" [("id","wpTextbox1")])
                           $ parseTags $ decodeString mwsrc) of
                  (TagText ('#':'r':'e':'d':'i':'r':'e':'c':'t':' ':'[':'[':xs):_) ->
                         takeWhile (/=']') xs
                  (TagText ('#':'R':'E':'D':'I':'R':'E':'C':'T':' ':'[':'[':xs):_) ->
                         takeWhile (/=']') xs
                  (TagText ('#':'R':'e':'d':'i':'r':'e':'c':'t':' ':'[':'[':xs):_) ->
                         takeWhile (/=']') xs
                  _ -> ""
      pageVersionUrl = wikiHost ++ wPrefix ++ "/index.php?title=" ++ page ++
                         if vId version > 0
                         then "&oldid=" ++ printf "%06d" (vId version)
                         else ""
  src <- if null redir
            then openURL' pageVersionUrl
            else return ""

  -- convert the page
  let nonSpan (TagOpen "span" _) = False
      nonSpan (TagClose "span")  = False
      nonSpan _                  = True
  -- content marked by "start content"/"end content" comments
  let tags = handleInlineCode    -- change inline code divs to code tags
             $ removeToc         -- remove TOC
             $ filter nonSpan    -- remove span tags
             $ tri'
      tri' =   takeWhile (~/= TagComment " /bodycontent ")
             $ dropWhile (~/= TagComment " bodycontent ")
             $ ped'
      ped' =   parseTags
             $ decodeString src  -- decode UTF-8
  let (body,foot) = break (~== TagOpen "div" [("class","printfooter")]) tags
  let categories = getCategories  -- extract categories
                 $ dropWhile (~/= TagOpen "p" [("class","catlinks")]) foot
  let html = renderTags body
  let doc' = bottomUp removeRawInlines   -- remove raw HTML
             $ bottomUp (handleHeaders . fixCodeBlocks . removeRawBlocks)
             $ readHtml def html
  -- handle wikilinks and images
  let subdir = not $ null $ takeDirectory fname
  doc'' <- bottomUpM (handleLinksImages fs subdir) doc'
  let md = if null redir
              then writeMarkdown def doc''
              else "See [" ++ fromUrlString redir ++ "](" ++ '/':fromUrlString redir ++ ")."
      desc = (printf "'%s' r%s, %d->%d" page' (show (vId version)) (length src) (length md)) :: String

  if ((length md) == 0)
  then printf "; WARNING: empty markdown from mediawiki: %s\n\nped':\n%s\n\ntri':\n%s\n\ntags:\n%s\n\nhtml:\n%s\n\ndoc':\n%s\n\ndoc'':\n%s\n"
              desc
              (show ped')
              (show tri')
              (show tags)
              (show html)
              (show doc')
              (show doc'')
  else printf "; adding %s\n" desc

  -- add header with categories
  let auth = vUser version
  let descr = vDescription version ++ " (#" ++ show (vId version) ++ ", " ++
                vDate version ++ ")"
  addToWiki fs fname auth descr $
     (if null categories
         then ""
         else "---\ncategories: " ++ intercalate "," categories ++ "\n...\n\n")
     ++ md ++ "\n"

-- remove <table id="toc"> (TOC)
removeToc :: [Tag String] -> [Tag String]
removeToc (t@(TagOpen "table" _) : ts) | fromAttrib "id" t == "toc" =
  removeToc $ dropWhile (~/= TagClose "table") ts
removeToc (t:ts) = t : removeToc ts
removeToc [] = []

-- add page to wiki
addToWiki :: Contents a => FileStore -> String -> String -> String -> a -> IO ()
addToWiki fs fname auth desc content = catch
  (save fs fname (Author auth "") desc content) $ \(e :: FileStoreError) ->
       putStrLn ("! Could not add " ++ fname ++ ": " ++ show e)

-- extract categories from <a ... title="Category:"> tags
getCategories :: [Tag String] -> [String]
getCategories (t@(TagOpen "a" _) : xs) =
  case fromAttrib "title" t of
        x | "Category:" `isPrefixOf` x ->
             stripPref "Category:" x : getCategories xs
        _ -> getCategories xs
getCategories (x:xs) = getCategories xs
getCategories [] = []

-- Convert underline to space
ulToSpace :: String -> String
ulToSpace = map go
  where go '_' = ' '
        go c   = c

removeRawBlocks :: Block -> Block
removeRawBlocks (RawBlock _ _) = Null
removeRawBlocks (Para [LineBreak]) = Null
removeRawBlocks x = x

removeRawInlines :: Inline -> Inline
removeRawInlines (RawInline _ _) = Str ""
removeRawInlines x = x

-- Inline code is represented by an unbelievably complex nested div,
-- even in block contexts!  We just extract the code and put it in
-- a code tag with an appropriate attribute, so pandoc can handle it.
handleInlineCode :: [Tag String] -> [Tag String]
handleInlineCode (TagOpen "div" [("class","inline-code")] :
     TagOpen "div" _ : TagOpen "div" attrs : ys) =
  TagOpen "code" [("class",cls)] : TagText code : TagClose "code" :
     handleInlineCode xs
  where cls = case lookup "class" attrs of
                  Just z -> stripPref "source-" z
                  Nothing -> ""
        (codes,ws) = span isTagText ys
        code = concatMap fromTagText codes
        xs = case ws of
                  (TagClose "div" : TagClose "div" : TagClose "div" :zs) -> zs
                  _ -> ws
handleInlineCode (x:xs) = x:handleInlineCode xs
handleInlineCode [] = []

-- Handle links and images, converting URLs and fetching images when needed,
-- adding them to the repository.
handleLinksImages :: FileStore -> Bool -> Inline -> IO Inline
handleLinksImages fs insubdir (Link lab (src,tit))
  | (wikiHost ++ wikiPrefix) `isPrefixOf` src ||
    (wikiHost ++ "/wikiupload") `isPrefixOf` src ||
    (wikiHostNoWWW ++ wikiPrefix) `isPrefixOf` src ||
    (wikiHostNoWWW ++ "/wikiupload") `isPrefixOf` src =
      let drop_prefix = stripPref wikiHost . stripPref wikiHostNoWWW
      in  handleLinksImages fs insubdir (Link lab (drop_prefix src, drop_prefix tit))
  | "/wikiupload/" `isPrefixOf` src = do  -- uploads like ps and pdf files
      let fname = "Upload/" ++ fromUrl (takeFileName src)
      addResource fs fname src
      return $ Link lab ('/':fname,"")
  | (wikiPrefix ++ "/Image:") `isPrefixOf` src =
      return $ Link lab ("/Image/" ++ fromUrl (stripPref (wikiPrefix ++ "Image:") src),"")
  | wikiPrefix `isPrefixOf` src = do
    let suff = fromUrl $ stripPref wikiPrefix src
    let suff' = if "Category:" `isPrefixOf` suff
                   then "_category/" ++ drop 9 suff
                   else suff
    if suff' == fromUrlString tit then
       if stringify lab == tit then
          if insubdir then                    -- in gitit a link is relative
            return $ Link lab ('/':tit,"")    -- this will change in gitit2
          else
            return $ Link lab ("","")
       else
          return $ Link lab ('/':tit,tit)
    else
       return $ Link lab ('/':suff',"")
  | otherwise = return $ Link lab (src,tit)
handleLinksImages fs insubdir (Image alt (src,tit))
  | (wikiHost ++ wikiPrefix) `isPrefixOf` src ||
    (wikiHost ++ "/wikiupload") `isPrefixOf` src ||
    (wikiHostNoWWW ++ wikiPrefix) `isPrefixOf` src ||
    (wikiHostNoWWW ++ "/wikiupload") `isPrefixOf` src =
      let drop_prefix = stripPref wikiHost . stripPref wikiHostNoWWW
      in  handleLinksImages fs insubdir (Image alt (drop_prefix src, drop_prefix tit))
    -- math images have tex source in alt attribute
  | "/wikiupload/math" `isPrefixOf` src =
      return $ Math InlineMath $ strip $ stringify alt
  | "/wikiupload/" `isPrefixOf` src = do
      let fname = "Image/" ++ fromUrl (takeFileName src)
      addResource fs fname src
      return $ Image alt ('/':fname,"")
  | otherwise = return $ Image alt (src,tit)
handleLinksImages _ _ x = return x

-- get image from web or cache and add to repository
addResource :: FileStore -> String -> String -> IO ()
addResource fs fname url = do
  res <- readIORef resources
  unless (fname `elem` res) $ do
    catch (latest fs fname >> putStrLn ("Skipping " ++ fname)) $
      \(e :: FileStoreError) -> do
         raw <- BC.pack `fmap` openURL' (wikiHost ++ url)
         putStrLn $ "Adding resource: " ++ fname
         modifyIORef resources (fname:)
         addToWiki fs fname "hw2gitit" "Import from haskellwiki" raw

-- remove numbering from headers.
handleHeaders (Header lev a xs) = Header lev a xs'
  where xs' = dropWhile (==Space) $ dropWhile (== Str ".")
            $ dropWhile (==Space) $ dropWhile isNum xs
        isNum (Str ys) = all (\c -> isDigit c || c == '.') ys
        isNum z = False
handleHeaders (Para (LineBreak:xs)) = Para xs
handleHeaders x = x

-- Change attribute on code blocks from source-X to X.
fixCodeBlocks (CodeBlock (id',classes,attrs) code) =
  CodeBlock (id', map (stripPref "source-") classes, attrs) code
fixCodeBlocks x = x
