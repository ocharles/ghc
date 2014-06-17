{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE AutoDeriveTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Applicative
-- Copyright   :  Conor McBride and Ross Paterson 2005
-- License     :  BSD-style (see the LICENSE file in the distribution)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- This module describes a structure intermediate between a functor and
-- a monad (technically, a strong lax monoidal functor).  Compared with
-- monads, this interface lacks the full power of the binding operation
-- '>>=', but
--
-- * it has more instances.
--
-- * it is sufficient for many uses, e.g. context-free parsing, or the
--   'Data.Traversable.Traversable' class.
--
-- * instances can perform analysis of computations before they are
--   executed, and thus produce shared optimizations.
--
-- This interface was introduced for parsers by Niklas R&#xF6;jemo, because
-- it admits more sharing than the monadic interface.  The names here are
-- mostly based on parsing work by Doaitse Swierstra.
--
-- For more details, see
-- <http://www.soi.city.ac.uk/~ross/papers/Applicative.html Applicative Programming with Effects>,
-- by Conor McBride and Ross Paterson.

module Control.Applicative (
    -- * Applicative functors
    Applicative(..),
    -- * Alternatives
    Alternative(..),
    -- * Instances
    Const(..), WrappedMonad(..), WrappedArrow(..), ZipList(..),
    -- * Utility functions
    (<$>), (<$), (<**>),
    liftA, liftA2, liftA3,
    optional,
    ) where

import Prelude hiding (id,(.))

import Control.Category
import Control.Arrow
import Control.Monad (liftM, ap, MonadPlus(..))
import Control.Monad.ST.Safe (ST)
import qualified Control.Monad.ST.Lazy.Safe as Lazy (ST)
import Data.Functor ((<$>), (<$))
import Data.Monoid (Monoid(..))
import Data.Proxy

import Text.ParserCombinators.ReadP (ReadP)
import Text.ParserCombinators.ReadPrec (ReadPrec)

import GHC.Conc (STM, retry, orElse)
import GHC.Generics

infixl 3 <|>
infixl 4 <*>, <*, *>, <**>

-- | A functor with application, providing operations to
--
-- * embed pure expressions ('pure'), and
--
-- * sequence computations and combine their results ('<*>').
--
-- A minimal complete definition must include implementations of these
-- functions satisfying the following laws:
--
-- [/identity/]
--
--      @'pure' 'id' '<*>' v = v@
--
-- [/composition/]
--
--      @'pure' (.) '<*>' u '<*>' v '<*>' w = u '<*>' (v '<*>' w)@
--
-- [/homomorphism/]
--
--      @'pure' f '<*>' 'pure' x = 'pure' (f x)@
--
-- [/interchange/]
--
--      @u '<*>' 'pure' y = 'pure' ('$' y) '<*>' u@
--
-- The other methods have the following default definitions, which may
-- be overridden with equivalent specialized implementations:
--
--   * @u '*>' v = 'pure' ('const' 'id') '<*>' u '<*>' v@
--
--   * @u '<*' v = 'pure' 'const' '<*>' u '<*>' v@
--
-- As a consequence of these laws, the 'Functor' instance for @f@ will satisfy
--
--   * @'fmap' f x = 'pure' f '<*>' x@
--
-- If @f@ is also a 'Monad', it should satisfy
--
--   * @'pure' = 'return'@
--
--   * @('<*>') = 'ap'@
--
-- (which implies that 'pure' and '<*>' satisfy the applicative functor laws).

class Functor f => Applicative f where
    -- | Lift a value.
    pure :: a -> f a

    -- | Sequential application.
    (<*>) :: f (a -> b) -> f a -> f b

    -- | Sequence actions, discarding the value of the first argument.
    (*>) :: f a -> f b -> f b
    (*>) = liftA2 (const id)

    -- | Sequence actions, discarding the value of the second argument.
    (<*) :: f a -> f b -> f a
    (<*) = liftA2 const

-- | A monoid on applicative functors.
--
-- Minimal complete definition: 'empty' and '<|>'.
--
-- If defined, 'some' and 'many' should be the least solutions
-- of the equations:
--
-- * @some v = (:) '<$>' v '<*>' many v@
--
-- * @many v = some v '<|>' 'pure' []@
class Applicative f => Alternative f where
    -- | The identity of '<|>'
    empty :: f a
    -- | An associative binary operation
    (<|>) :: f a -> f a -> f a

    -- | One or more.
    some :: f a -> f [a]
    some v = some_v
      where
        many_v = some_v <|> pure []
        some_v = (:) <$> v <*> many_v

    -- | Zero or more.
    many :: f a -> f [a]
    many v = many_v
      where
        many_v = some_v <|> pure []
        some_v = (:) <$> v <*> many_v

-- instances for Prelude types

instance Applicative Maybe where
    pure = return
    (<*>) = ap

instance Alternative Maybe where
    empty = Nothing
    Nothing <|> r = r
    l       <|> _ = l

instance Applicative [] where
    pure = return
    (<*>) = ap

instance Alternative [] where
    empty = []
    (<|>) = (++)

instance Applicative IO where
    pure = return
    (<*>) = ap

instance Applicative (ST s) where
    pure = return
    (<*>) = ap

instance Applicative (Lazy.ST s) where
    pure = return
    (<*>) = ap

instance Applicative STM where
    pure = return
    (<*>) = ap

instance Alternative STM where
    empty = retry
    (<|>) = orElse

instance Applicative ((->) a) where
    pure = const
    (<*>) f g x = f x (g x)

instance Monoid a => Applicative ((,) a) where
    pure x = (mempty, x)
    (u, f) <*> (v, x) = (u `mappend` v, f x)

instance Applicative (Either e) where
    pure          = Right
    Left  e <*> _ = Left e
    Right f <*> r = fmap f r

instance Applicative ReadP where
    pure = return
    (<*>) = ap

instance Alternative ReadP where
    empty = mzero
    (<|>) = mplus

instance Applicative ReadPrec where
    pure = return
    (<*>) = ap

instance Alternative ReadPrec where
    empty = mzero
    (<|>) = mplus

instance Arrow a => Applicative (ArrowMonad a) where
   pure x = ArrowMonad (arr (const x))
   ArrowMonad f <*> ArrowMonad x = ArrowMonad (f &&& x >>> arr (uncurry id))

instance ArrowPlus a => Alternative (ArrowMonad a) where
   empty = ArrowMonad zeroArrow
   ArrowMonad x <|> ArrowMonad y = ArrowMonad (x <+> y)

-- new instances

newtype Const a b = Const { getConst :: a }
                  deriving (Generic, Generic1)

instance Functor (Const m) where
    fmap _ (Const v) = Const v

-- Added in base-4.7.0.0
instance Monoid a => Monoid (Const a b) where
    mempty = Const mempty
    mappend (Const a) (Const b) = Const (mappend a b)

instance Monoid m => Applicative (Const m) where
    pure _ = Const mempty
    Const f <*> Const v = Const (f `mappend` v)

newtype WrappedMonad m a = WrapMonad { unwrapMonad :: m a }
                         deriving (Generic, Generic1)

instance Monad m => Functor (WrappedMonad m) where
    fmap f (WrapMonad v) = WrapMonad (liftM f v)

instance Monad m => Applicative (WrappedMonad m) where
    pure = WrapMonad . return
    WrapMonad f <*> WrapMonad v = WrapMonad (f `ap` v)

-- Added in base-4.7.0.0 (GHC Trac #8218)
instance Monad m => Monad (WrappedMonad m) where
    return = WrapMonad . return
    a >>= f = WrapMonad (unwrapMonad a >>= unwrapMonad . f)

instance MonadPlus m => Alternative (WrappedMonad m) where
    empty = WrapMonad mzero
    WrapMonad u <|> WrapMonad v = WrapMonad (u `mplus` v)

newtype WrappedArrow a b c = WrapArrow { unwrapArrow :: a b c }
                           deriving (Generic, Generic1)

instance Arrow a => Functor (WrappedArrow a b) where
    fmap f (WrapArrow a) = WrapArrow (a >>> arr f)

instance Arrow a => Applicative (WrappedArrow a b) where
    pure x = WrapArrow (arr (const x))
    WrapArrow f <*> WrapArrow v = WrapArrow (f &&& v >>> arr (uncurry id))

instance (ArrowZero a, ArrowPlus a) => Alternative (WrappedArrow a b) where
    empty = WrapArrow zeroArrow
    WrapArrow u <|> WrapArrow v = WrapArrow (u <+> v)

-- | Lists, but with an 'Applicative' functor based on zipping, so that
--
-- @f '<$>' 'ZipList' xs1 '<*>' ... '<*>' 'ZipList' xsn = 'ZipList' (zipWithn f xs1 ... xsn)@
--
newtype ZipList a = ZipList { getZipList :: [a] }
                  deriving (Show, Eq, Ord, Read, Generic, Generic1)

instance Functor ZipList where
    fmap f (ZipList xs) = ZipList (map f xs)

instance Applicative ZipList where
    pure x = ZipList (repeat x)
    ZipList fs <*> ZipList xs = ZipList (zipWith id fs xs)

instance Applicative Proxy where
    pure _ = Proxy
    {-# INLINE pure #-}
    _ <*> _ = Proxy
    {-# INLINE (<*>) #-}

-- Instances for GHC.Generics

instance Applicative U1 where
  pure _ = U1
  U1 <*> U1 = U1

instance Alternative U1 where
  empty = U1
  U1 <|> U1 = U1

instance Applicative Par1 where
  pure a = Par1 a
  (Par1 f) <*> (Par1 x) = Par1 (f x)

instance Applicative f => Applicative (Rec1 f) where
  pure a = Rec1 (pure a)
  (Rec1 f) <*> (Rec1 x) = Rec1 (f <*> x)

instance Alternative f => Alternative (Rec1 f) where
  empty = Rec1 empty
  (Rec1 l) <|> (Rec1 r) = Rec1 (l <|> r)

instance Applicative f => Applicative (M1 i c f) where
  pure a = M1 (pure a)
  (M1 f) <*> (M1 x) = M1 (f <*> x)

instance Alternative f => Alternative (M1 i c f) where
  empty = M1 empty
  (M1 l) <|> (M1 r) = M1 (l <|> r)

instance (Applicative f, Applicative g) => Applicative ((:*:) f g) where
  pure a = pure a :*: pure a
  (f :*: g) <*> (x :*: y) = (f <*> x) :*: (g <*> y)

instance (Alternative f, Alternative g) => Alternative ((:*:) f g) where
    empty = empty :*: empty
    (x1 :*: y1) <|> (x2 :*: y2) = (x1 <|> x2) :*: (y1 <|> y2)

instance (Applicative f, Applicative g) => Applicative ((:.:) f g) where
    pure x = Comp1 (pure (pure x))
    Comp1 f <*> Comp1 x = Comp1 ((<*>) <$> f <*> x)

instance (Alternative f, Applicative g) => Alternative ((:.:) f g) where
    empty = Comp1 empty
    Comp1 x <|> Comp1 y = Comp1 (x <|> y)

-- extra functions

-- | A variant of '<*>' with the arguments reversed.
(<**>) :: Applicative f => f a -> f (a -> b) -> f b
(<**>) = liftA2 (flip ($))

-- | Lift a function to actions.
-- This function may be used as a value for `fmap` in a `Functor` instance.
liftA :: Applicative f => (a -> b) -> f a -> f b
liftA f a = pure f <*> a

-- | Lift a binary function to actions.
liftA2 :: Applicative f => (a -> b -> c) -> f a -> f b -> f c
liftA2 f a b = f <$> a <*> b

-- | Lift a ternary function to actions.
liftA3 :: Applicative f => (a -> b -> c -> d) -> f a -> f b -> f c -> f d
liftA3 f a b c = f <$> a <*> b <*> c

-- | One or none.
optional :: Alternative f => f a -> f (Maybe a)
optional v = Just <$> v <|> pure Nothing
