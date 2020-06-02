{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RecursiveDo #-}

module Codec.Candid.Encode (encodeValues, encodeDynValues) where

import Numeric.Natural
import qualified Data.Vector as V
import qualified Data.Text.Encoding as T
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Builder as B
import qualified Data.Map as M
import Control.Monad.State.Lazy
import Data.Bifunctor
import Data.Word
import Data.List
import Data.Void
import Control.Monad.RWS.Lazy
import Data.Serialize.LEB128
import Data.Text.Prettyprint.Doc

import Codec.Candid.Data
import Codec.Candid.TypTable
import Codec.Candid.Types
import Codec.Candid.Infer


-- | Encodes a Candid value given in the dynamic 'Value' form, at inferred type.
--
-- This may fail if the values have inconsistent types. It does not use the
-- @reserved@ supertype (unless explicitly told to).
encodeDynValues :: [Value] -> Either String B.Builder
encodeDynValues vs = do
    ts <- inferTypes vs
    return $ encodeValues (SeqDesc mempty ts) vs

-- | Encodes a Candid value given in the dynamic 'Value' form, at given type.
--
-- This fails if the values do not match the given type.
encodeValues :: SeqDesc -> [Value] -> B.Builder
encodeValues t vs = mconcat
    [ B.stringUtf8 "DIDL"
    , typTable t
    , encodeSeq (tieKnot t) vs
    ]

encodeSeq :: [Type Void] -> [Value] -> B.Builder
encodeSeq [] _ = mempty -- NB: Subtyping
encodeSeq (t:ts) (x:xs) = encodeVal t x <> encodeSeq ts xs
encodeSeq _ [] = error "encodeSeq: Not enough values"

encodeVal :: Type Void -> Value -> B.Builder
encodeVal BoolT (BoolV False) = B.word8 0
encodeVal BoolT (BoolV True) = B.word8 1
encodeVal NatT (NatV n) = buildLEB128 n
encodeVal Nat8T (Nat8V n) = B.word8 n
encodeVal Nat16T (Nat16V n) = B.word16LE n
encodeVal Nat32T (Nat32V n) = B.word32LE n
encodeVal Nat64T (Nat64V n) = B.word64LE n
encodeVal IntT (NatV n) = buildSLEB128 (fromIntegral n :: Integer) -- NB Subtyping
encodeVal IntT (IntV n) = buildSLEB128 n
encodeVal Int8T (Int8V n) = B.int8 n
encodeVal Int16T (Int16V n) = B.int16LE n
encodeVal Int32T (Int32V n) = B.int32LE n
encodeVal Int64T (Int64V n) = B.int64LE n
encodeVal Float32T (Float32V n) = B.floatLE n
encodeVal Float64T (Float64V n) = B.doubleLE n
encodeVal TextT (TextV t) = encodeBytes (BS.fromStrict (T.encodeUtf8 t))
encodeVal NullT NullV = mempty
encodeVal ReservedT _ = mempty -- NB Subtyping
encodeVal (OptT _) (OptV Nothing) = B.word8 0
encodeVal (OptT t) (OptV (Just x)) = B.word8 1 <> encodeVal t x
encodeVal (VecT t) (VecV xs) =
    buildLEB128Int (V.length xs) <>
    foldMap (encodeVal t) xs
encodeVal (RecT fs) (TupV vs) = encodeVal (RecT fs) (tupV vs)
encodeVal (RecT fs) (RecV vs) = encodeRec fs' vs'
  where
    fs' = sortOn fst $ map (first hashFieldName) fs
    vs' = map (first hashFieldName) vs
encodeVal (VariantT fs) (VariantV f x) =
    case lookup (hashFieldName f) fs' of
        Just (i, t) -> buildLEB128Int @Word32 i <> encodeVal t x
        Nothing -> error $ "encodeVal: Variant field " ++ show (pretty f) ++ " not found"
  where
    fs' = sortOn fst [ (hashFieldName n, (i,t)) | ((n,t), i) <- zip fs [0..] ]
encodeVal PrincipalT (PrincipalV (Principal s)) = B.int8 1 <> encodeBytes s
encodeVal BlobT (BlobV b) = encodeBytes b
encodeVal (VecT Nat8T) (BlobV b) = encodeBytes b
encodeVal (RefT x) _ = absurd x
encodeVal t v = error $ "Unexpected value at type " ++ show (pretty t) ++ ": " ++ show (pretty v)

encodeBytes :: BS.ByteString -> B.Builder
encodeBytes bytes = buildLEB128Int (BS.length bytes) <> B.lazyByteString bytes

-- Encodes the fields in order specified by the type
encodeRec :: [(Word32, Type Void)] -> [(Word32, Value)] -> B.Builder
encodeRec [] _ = mempty -- NB: Subtyping
encodeRec ((n,t):fs) vs
    | Just v <- lookup n vs = encodeVal t v <> encodeRec fs vs
    | otherwise = error $ "Missing record field " ++ show (pretty n)

type TypTableBuilder k = RWS () B.Builder (M.Map (Type k) Integer, Natural)

typTable :: SeqDesc -> B.Builder
typTable (SeqDesc m (ts :: [Type k])) = mconcat
    [ buildLEB128 typ_tbl_len
    , typ_tbl
    , leb128Len ts
    , foldMap buildSLEB128 typ_idxs
    ]
  where
    (typ_idxs, (_, typ_tbl_len), typ_tbl) = runRWS (mapM go ts) () (M.empty, 0)

    addCon :: Type k -> TypTableBuilder k B.Builder -> TypTableBuilder k Integer
    addCon t body = gets (M.lookup t . fst) >>= \case
        Just i -> return i
        Nothing -> mdo
            i <- gets snd
            modify' (first (M.insert t (fromIntegral i)))
            modify' (second succ)
            tell b
            b <- body
            return $ fromIntegral i

    go :: Type k -> TypTableBuilder k Integer
    go t = case t of
      NullT     -> return $ -1
      BoolT     -> return $ -2
      NatT      -> return $ -3
      IntT      -> return $ -4
      Nat8T     -> return $ -5
      Nat16T    -> return $ -6
      Nat32T    -> return $ -7
      Nat64T    -> return $ -8
      Int8T     -> return $ -9
      Int16T    -> return $ -10
      Int32T    -> return $ -11
      Int64T    -> return $ -12
      Float32T  -> return $ -13
      Float64T  -> return $ -14
      TextT     -> return $ -15
      ReservedT -> return $ -16
      EmptyT    -> return $ -17

      -- Constructors
      OptT t' -> addCon t $ do
        ti <- go t'
        return $ buildSLEB128 @Integer (-18) <> buildSLEB128 ti
      VecT t' -> addCon t $ do
        ti <- go t'
        return $ buildSLEB128 @Integer (-19) <> buildSLEB128 ti
      RecT fs -> addCon t $ recordLike (-20) fs
      VariantT fs -> addCon t $ recordLike (-21) fs

      -- References
      PrincipalT -> return $ -24

      -- Short-hands
      BlobT -> addCon t $
        -- blob = vec nat8
        return $ buildSLEB128 @Integer (-19) <> buildSLEB128 @Integer (-5)

      RefT t -> go (m M.! t)

    goFields :: Fields k -> TypTableBuilder k [(Word32, Integer)]
    goFields [] = return []
    goFields ((fn, t):fs) = do
        ti <- go t
        tis <- goFields fs
        return $ (hashFieldName fn, ti) : tis

    recordLike :: Integer -> Fields k -> TypTableBuilder k B.Builder
    recordLike n fs = do
        tis <- goFields fs
        return $ mconcat
            [ buildSLEB128 n
            , leb128Len tis
            , foldMap (\(n,ti) -> buildLEB128 n <> buildSLEB128 ti) $
              sortOn fst tis -- TODO: Check duplicates maybe?
            ]

buildLEB128Int :: Integral a => a -> B.Builder
buildLEB128Int = buildLEB128 @Natural . fromIntegral

leb128Len :: [a] -> B.Builder
leb128Len = buildLEB128Int . length

