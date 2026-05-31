module Kiroku.Cli.Command (
    KirokuCommand (..),
) where

data KirokuCommand
    = KirokuNoCommand
    deriving stock (Eq, Show)
