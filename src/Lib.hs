module Lib
  ( someFunc
  )
where

import           Lexer
import           Parser

someFunc :: IO ()
someFunc = getContents >>= print . parse . scan
