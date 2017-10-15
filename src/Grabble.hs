{- | Drawing without replacement, from https://wiki.haskell.org/Random_shuffle -}

module Grabble (grabble, grabbleOnce) where

import           Control.Monad.Random
import           Data.Array.IArray    (elems)
import           Data.Array.ST


{- | @grabble xs m n@ is /O(m*n')/, where @n' = min n (length xs)@
     Chooses @n@ elements from @xs@, without putting back,
     and that @m@ times. -}
grabble :: MonadRandom m => [a] -> Int -> Int -> m [[a]]
grabble xs m n = do
    swapss <- replicateM m $ forM [0 .. min (maxIx - 1) n] $ \i -> do
                j <- getRandomR (i, maxIx)
                return (i, j)
    return $ map (take n . swapElems xs) swapss
    where
        maxIx   = length xs - 1

grabbleOnce :: MonadRandom m => [a] -> Int -> m [a]
grabbleOnce xs n = head `liftM` grabble xs 1 n

swapElems  :: [a] -> [(Int, Int)] -> [a]
swapElems xs swaps = elems $ runSTArray (do
    arr <- newListArray (0, maxIx) xs
    mapM_ (swap arr) swaps
    return arr)
    where
        maxIx   = length xs - 1
        swap arr (i,j) = do
            vi <- readArray arr i
            vj <- readArray arr j
            writeArray arr i vj
            writeArray arr j vi

