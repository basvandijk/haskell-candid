module Codec.Candid.Parse where

import qualified Data.ByteString.Lazy as BS
import qualified Data.Text.Encoding as T
import qualified Data.Text as T
import qualified Data.Vector as V
import Text.Parsec
import Text.Parsec.String
import Data.Bifunctor
import Data.Char
import Data.Functor
import Numeric.Natural
import Numeric
import Control.Monad
import Data.Void
import Text.Read (readMaybe)
import Data.Scientific

import Codec.Candid.Data
import Codec.Candid.Types
import Codec.Candid.FieldName

-- | A candid service, as a list of methods with argument and result types
--
-- (no support for annotations like query yet)
type DidFile = [ (T.Text, [Type Void], [Type Void]) ]

-- | Parses a Candid description (@.did@) from a string
parseDid :: String -> Either String DidFile
parseDid = first show . parse (allInput fileP) "Candid service"

parseDidType :: String -> Either String (Type Void)
parseDidType = first show . parse (allInput dataTypeP) "Candid type"

-- | Parses a Candid textual value from a string
parseValue :: String -> Either String Value
parseValue = first show . parse (allInput valueP) "Candid value"

-- | Parses a sequence of  Candid textual values from a string
parseValues :: String -> Either String [Value]
parseValues = first show . parse (allInput valuesP) "Candid values (argument sequence)"


allInput :: Parser a -> Parser a
allInput = between spaces eof

fileP :: Parser DidFile
fileP = many defP *> actorP

defP :: Parser ()
defP = typeP <|> importP

typeP :: Parser ()
typeP = s "type" *> fail "type definitions not yet supported"

importP :: Parser ()
importP = s "import" *> fail "imports not yet supported"

actorP :: Parser DidFile
actorP = s "service" *> optional idP *> s ":" *> actorTypeP -- TODO could be a type id

actorTypeP :: Parser DidFile
actorTypeP = braceSemi methTypeP

methTypeP :: Parser (T.Text, [Type Void], [Type Void])
methTypeP = do
    n <- nameP
    s ":"
    (ts1, ts2) <- funcTypeP  -- TODO could be a type id
    return (n, ts1, ts2)

funcTypeP :: Parser ([(Type Void)], [(Type Void)])
funcTypeP = (,) <$> seqP <* s "->" <*> seqP <* many funcAnnP

funcAnnP :: Parser () -- TODO: Annotations are dropped
funcAnnP = s "oneway" <|> s "query"

nameP :: Parser T.Text
nameP = textP <|> T.pack <$> idP <?> "name"

textP :: Parser T.Text
textP = T.pack <$> l (between (char '"') (char '"') (many stringElem)) <?> "text"

blobP :: Parser BS.ByteString
blobP = BS.concat <$> l (between (char '"') (char '"') (many blobElem)) <?> "blob"

blobElem :: Parser BS.ByteString
blobElem = choice
    [ try (char '\\' *> lookAhead hexdigit) *> do
        raw <- replicateM 2 hexdigit
        case readHex raw of
            [(n,"")] -> return (BS.singleton (fromIntegral (n::Integer)))
            _ -> fail "Internal parsing error parsing hex digits"
    , BS.fromStrict . T.encodeUtf8 . T.singleton <$> stringElem
    ]

stringElem :: Parser Char
stringElem = l $ (char '\\' *> go) <|> noneOf "\""
  where
    go :: Parser Char
    go = choice
        [ '\t' <$ char 't'
        , '\n' <$ char 'n'
        , '\r' <$ char 'r'
        , '\"' <$ char '\"'
        , '\'' <$ char '\''
        , '\"' <$ char '\"'
        , between (string "u{") (string "}") hexnum
        ]

    hexnum :: Parser Char
    hexnum = do
        raw <- concat <$> many1 (replicateM 2 hexdigit)
        case readHex raw of
            [(n,"")] -> return (chr n)
            _ -> fail $ "Invalid hex string " ++ show raw

hexdigit :: Parser Char
hexdigit = oneOf "0123456789ABCDEFabcdef"

seqP :: Parser [Type Void]
seqP = parenComma argTypeP

argTypeP :: Parser (Type Void)
argTypeP = dataTypeP <|> (nameP *> s ":" *> dataTypeP)

dataTypeP :: Parser (Type Void)
dataTypeP = primTypeP <|> constTypeP -- TODO: Ids, reftypes

primTypeP :: Parser (Type Void)
primTypeP = choice
    [ NatT <$ k "nat"
    , Nat8T <$ k "nat8"
    , Nat16T <$ k "nat16"
    , Nat32T <$ k "nat32"
    , Nat64T <$ k "nat64"
    , IntT <$ k "int"
    , Int8T <$ k "int8"
    , Int16T <$ k "int16"
    , Int32T <$ k "int32"
    , Int64T <$ k "int64"
    , Float32T <$ k "float32"
    , Float64T <$ k "float64"
    , BoolT <$ k "bool"
    , TextT <$ k "text"
    , NullT <$ k "null"
    , ReservedT <$ k "reserved"
    , EmptyT <$ k "empty"
    , BlobT <$ k "blob"
    , PrincipalT <$ k "principal"
    ]

constTypeP :: Parser (Type Void)
constTypeP = choice
  [ OptT <$ k "opt" <*> dataTypeP
  , VecT <$ k "vec" <*> dataTypeP
  , RecT <$ k "record" <*> braceSemi (fieldTypeP False)
  , VariantT <$ k "variant" <*> braceSemi (fieldTypeP True)
  ]

fieldTypeP :: Bool -> Parser (FieldName, Type Void)
fieldTypeP in_variant = (,)
  <$> (hashedField . fromIntegral <$> natP <|>  labledField <$> nameP)
  <*> ((s ":" *> dataTypeP) <|> NullT <$ guard in_variant)

idP :: Parser String
idP = l ((:)
  <$> satisfy (\c -> isAscii c && isLetter c || c == '_')
  <*> many (satisfy (\c -> isAscii c && isAlphaNum c || c == '_'))
  ) <?> "id"

valuesP :: Parser [Value]
valuesP = (parenComma annValueP <?> "argument sequence")
       <|> ((:[]) <$> annValueP) -- for convenience

annValueP :: Parser Value
annValueP =
  parens annValueP <|> do -- this parser allows extra parentheses
      v <- valueP
      s ":" *> do
            t <- dataTypeP
            smartAnnV v t
       <|> return v

smartAnnV :: Value -> Type Void -> Parser Value
smartAnnV (NumV n) Nat8T = Nat8V <$> toBounded n
smartAnnV (NumV n) Nat16T = Nat16V <$> toBounded n
smartAnnV (NumV n) Nat32T = Nat32V <$> toBounded n
smartAnnV (NumV n) Nat64T = Nat64V <$> toBounded n
smartAnnV (NumV n) Int8T = Int8V <$> toBounded n
smartAnnV (NumV n) Int16T = Int16V <$> toBounded n
smartAnnV (NumV n) Int32T = Int32V <$> toBounded n
smartAnnV (NumV n) Int64T = Int64V <$> toBounded n
smartAnnV (NumV n) Float32T = return $ Float32V $ toRealFloat n
smartAnnV (NumV n) Float64T = return $ Float64V $ toRealFloat n
smartAnnV v ReservedT = return $ AnnV v ReservedT
smartAnnV _ _ = fail "Annotations are only supported around number literals"

toBounded :: (Integral a, Bounded a) => Scientific -> Parser a
toBounded v = maybe err return $ toBoundedInteger v
  where err = fail $ "Number literal out of bounds: " ++ show v

numP :: Parser Scientific
numP = l p >>= conv <?> "number"
  where
    p =(:) <$> oneOf "-+0123456789" <*> many (oneOf "-+.0123456789eE_")
    conv raw = case readMaybe (filter (/= '_') raw) of
        Nothing -> fail $ "Invald number literal: " ++ show raw
        Just s -> return s

valueP :: Parser Value
valueP = choice
  [ parens annValueP
  , NumV <$> numP
  , BoolV True <$ k "true"
  , BoolV False <$ k "false"
  , TextV <$> textP
  , NullV <$ k "null"
  , OptV . Just <$ k "opt" <*> valueP
  , VecV . V.fromList <$ k "vec" <*> braceSemi annValueP
  , RecV <$ k "record" <*> braceSemi (fieldValP False)
  , uncurry VariantV <$ k "variant" <*> braces (fieldValP True)
  , PrincipalV <$ k "service" <*> (textP >>= either fail return . parsePrincipal)
  , BlobV <$ k "blob" <*> blobP
  ]

fieldValP :: Bool -> Parser (FieldName, Value)
fieldValP in_variant = (,)
  <$> (hashedField . fromIntegral <$> natP <|> labledField <$> nameP)
  <*> ((s "=" *> annValueP) <|> NullV <$ guard in_variant)

-- A lexeme
l :: Parser a -> Parser a
l x = x <* spaces

-- a symbol
s :: String -> Parser ()
s str = void (l (string str)) <?> str

-- a keyword
k :: String -> Parser ()
k str = try (void (l (string str <* no)) <?> str)
  where
    no = notFollowedBy (satisfy (\c -> isAscii c && isAlphaNum c || c == '_'))

natP :: Parser Natural
natP = l (read <$> many1 digit <?> "number")

braces :: Parser a -> Parser a
braces = between (s "{") (s "}")
braceSemi :: Parser a -> Parser [a]
braceSemi p = braces $ sepEndBy p (s ";")
parens :: Parser a -> Parser a
parens = between (s "(") (s ")")
parenComma :: Parser a -> Parser [a]
parenComma p = parens $ sepEndBy p (s ",")
