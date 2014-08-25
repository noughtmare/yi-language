{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_HADDOCK show-extensions #-}

-- |
-- Module      :  Yi.Lexer.Alex
-- License     :  GPL-2
-- Maintainer  :  yi-devel@googlegroups.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Utilities to turn a lexer generated by Alex into a 'Scanner' that
-- can be used by Yi. Most lexers will use the types defined here.
-- Some things are exported for use by lexers themselves through the
-- use of @Yi/Lexers/common.hsinc@.

module Yi.Lexer.Alex ( module Yi.Lexer.Alex
                     , (+~), (~-), Size(..), Stroke ) where

import           Control.Lens (_1, view)
import           Control.Lens.TH (makeLenses)
import qualified Data.Bits
import           Data.Char (ord)
import           Data.Function (on)
import           Data.Ix
import           Data.List (foldl')
import           Data.Ord (comparing)
import           Data.Word (Word8)
import           Yi.Style (StyleName)
import           Yi.Syntax hiding (mkHighlighter)
import           Yi.Utils

-- | Encode a Haskell String to a list of Word8 values, in UTF8 format.
utf8Encode :: Char -> [Word8]
utf8Encode = map fromIntegral . go . ord
 where
  go oc
   | oc <= 0x7f       = [oc]

   | oc <= 0x7ff      = [ 0xc0 + (oc `Data.Bits.shiftR` 6)
                        , 0x80 + oc Data.Bits..&. 0x3f
                        ]

   | oc <= 0xffff     = [ 0xe0 + (oc `Data.Bits.shiftR` 12)
                        , 0x80 + ((oc `Data.Bits.shiftR` 6) Data.Bits..&. 0x3f)
                        , 0x80 + oc Data.Bits..&. 0x3f
                        ]
   | otherwise        = [ 0xf0 + (oc `Data.Bits.shiftR` 18)
                        , 0x80 + ((oc `Data.Bits.shiftR` 12) Data.Bits..&. 0x3f)
                        , 0x80 + ((oc `Data.Bits.shiftR` 6) Data.Bits..&. 0x3f)
                        , 0x80 + oc Data.Bits..&. 0x3f
                        ]
type Byte = Word8

type IndexedStr = [(Point, Char)]
type AlexInput = (Char, [Byte],IndexedStr)
type Action hlState token = IndexedStr -> hlState -> (hlState, token)

-- | Lexer state
data AlexState lexerState = AlexState {
      stLexer  :: lexerState,   -- (user defined) lexer state
      lookedOffset :: !Point, -- Last offset looked at
      stPosn :: !Posn
    } deriving Show

data Tok t = Tok { tokT :: t
                 , tokLen  :: Size
                 , tokPosn :: Posn
                 } deriving Functor

instance Eq (Tok a) where
  (==) = (==) `on` tokPosn

tokToSpan :: Tok t -> Span t
tokToSpan (Tok t len posn) = Span (posnOfs posn) t (posnOfs posn +~ len)

tokFromT :: t -> Tok t
tokFromT t = Tok t 0 startPosn

tokBegin :: Tok t -> Point
tokBegin = posnOfs . tokPosn

tokEnd :: Tok t -> Point
tokEnd t = tokBegin t +~ tokLen t

instance Show t => Show (Tok t) where
    show tok = show (tokPosn tok) ++ ": " ++ show (tokT tok)

data Posn = Posn {
      posnOfs :: !Point
    , posnLine :: !Int
    , posnCol :: !Int
  } deriving (Eq, Ix)

-- TODO: Verify that this is right.  /Deniz
instance Ord Posn where
    compare = comparing posnOfs

instance Show Posn where
    show (Posn o l c) = "L" ++ show l ++ " " ++ "C" ++ show c ++ "@" ++ show o

startPosn :: Posn
startPosn = Posn 0 1 0

moveStr :: Posn -> IndexedStr -> Posn
moveStr posn str = foldl' moveCh posn (fmap snd str)

moveCh :: Posn -> Char -> Posn
moveCh (Posn o l c) '\t' = Posn (o+1) l       (((c+8) `div` 8)*8)
moveCh (Posn o l _) '\n' = Posn (o+1) (l+1)   0
moveCh (Posn o l c) _    = Posn (o+1) l       (c+1)

alexGetChar :: AlexInput -> Maybe (Char, AlexInput)
alexGetChar (_,_,[]) = Nothing
alexGetChar (_,b,(_,c):rest) = Just (c, (c,b,rest))

alexGetByte :: AlexInput -> Maybe (Word8,AlexInput)
alexGetByte (c, b:bs, s) = Just (b,(c,bs,s))
alexGetByte (_, [], [])    = Nothing
alexGetByte (_, [], c:s) = case utf8Encode (snd c) of
                             (b:bs) -> Just (b, ((snd c), bs, s))
                             [] -> Nothing

{-# ANN alexCollectChar "HLint: ignore Use String" #-}
alexCollectChar :: AlexInput -> [Char]
alexCollectChar (_, _, []) = []
alexCollectChar (_, b, (_, c):rest) = c : alexCollectChar (c, b, rest)

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar = view _1

-- | Return a constant token
actionConst :: token -> Action lexState token
actionConst token = \_str state -> (state, token)

-- | Return a constant token, and modify the lexer state
actionAndModify :: (lexState -> lexState) -> token -> Action lexState token
actionAndModify modifierFct token = \_str state -> (modifierFct state, token)

-- | Convert the parsed string into a token,
--   and also modify the lexer state
actionStringAndModify :: (s -> s) -> (String -> token) -> Action s token
actionStringAndModify modF f = \istr s -> (modF s, f $ fmap snd istr)

-- | Convert the parsed string into a token
actionStringConst :: (String -> token) -> Action lexState token
actionStringConst f = \indexedStr state -> (state, f $ fmap snd indexedStr)

type ASI s = (AlexState s, AlexInput)

-- | Function to (possibly) lex a single token and give us the
-- remaining input.
type TokenLexer l s t i = (l s, i) -> Maybe (t, (l s, i))

-- | Handy alias
type CharScanner = Scanner Point Char

-- | Generalises lexers. This allows us to easily use lexers which
-- don't want to be cornered into the types we have predefined here
-- and use in @common.hsinc@.
data Lexer l s t i = Lexer
  { _step :: TokenLexer l s t i
  , _starting :: s -> Point -> Posn -> l s
  , _withChars :: Char -> [(Point, Char)] -> i
  , _looked :: l s -> Point
  , _statePosn :: l s -> Posn
  , _lexEmpty :: t
  , _startingState :: s
  }

-- | Just like 'Lexer' but also knows how to turn its tokens into
-- 'StyleName's.
data StyleLexer l s t i = StyleLexer
  { _tokenToStyle :: t -> StyleName
  , _styleLexer :: Lexer l s (Tok t) i
  }

-- | 'StyleLexer' over 'ASI'.
type StyleLexerASI s t = StyleLexer AlexState s t AlexInput

-- | Defines a 'Lexer' for 'ASI'. This exists to make using the new
-- 'lexScanner' easier if you're using 'ASI' as all our lexers do
-- today, 23-08-2014.
commonLexer :: (ASI s -> Maybe (Tok t, ASI s))
            -> s
            -> Lexer AlexState s (Tok t) AlexInput
commonLexer l st0 = Lexer
  { _step = l
  , _starting = AlexState
  , _withChars = \c p -> (c, [], p)
  , _looked = lookedOffset
  , _statePosn = stPosn
  , _lexEmpty = error "Yi.Lexer.Alex.commonLexer: lexEmpty"
  , _startingState = st0
  }

-- | Combine a character scanner with a lexer to produce a token
-- scanner. May be used together with 'mkHighlighter' to produce a
-- 'Highlighter', or with 'linearSyntaxMode' to produce a 'Mode'.
lexScanner :: Lexer l s t i -> CharScanner -> Scanner (l s) t
lexScanner Lexer {..} src = Scanner
  { scanLooked = _looked
  , scanInit = _starting _startingState 0 startPosn
  , scanRun = \st -> case posnOfs $ _statePosn st of
      0 -> unfoldLexer _step (st, _withChars '\n' $ scanRun src 0)
      ofs -> case scanRun src (ofs -1) of
        [] -> []
        (_, ch) : rest -> unfoldLexer _step (st, _withChars ch rest)
  , scanEmpty = _lexEmpty
  }

-- | unfold lexer into a function that returns a stream of (state, token)
unfoldLexer :: ((state, input) -> Maybe (token, (state, input)))
            -> (state, input) -> [(state, token)]
unfoldLexer f b = case f b of
             Nothing -> []
             Just (t, b') -> (fst b, t) : unfoldLexer f b'

-- * Lenses
makeLensesWithSuffix "A" ''Posn
makeLensesWithSuffix "A" ''Tok
makeLenses ''Lexer
makeLenses ''StyleLexer
