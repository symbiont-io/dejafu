-- | Dynamic partial-order reduction.
module Test.DejaFu.DPOR
  ( -- * Scheduling decisions
    Decision(..)
  , tidOf
  , decisionOf
  , activeTid

  -- * DPOR state
  , DPOR(..)
  , initialState
  , toDot
  , toDotFiltered
  ) where

import Control.DeepSeq (NFData(..))
import Data.Char (ord)
import Data.List (foldl', intercalate)
import Data.Map.Strict (Map)
import Data.Set (Set)

import qualified Data.Map.Strict as M
import qualified Data.Set as S

-------------------------------------------------------------------------------
-- Scheduling decisions

-- | Scheduling decisions are based on the state of the running
-- program, and so we can capture some of that state in recording what
-- specific decision we made.
data Decision thread_id =
    Start thread_id
  -- ^ Start a new thread, because the last was blocked (or it's the
  -- start of computation).
  | Continue
  -- ^ Continue running the last thread for another step.
  | SwitchTo thread_id
  -- ^ Pre-empt the running thread, and switch to another.
  deriving (Eq, Show)

instance NFData thread_id => NFData (Decision thread_id) where
  rnf (Start    tid) = rnf tid
  rnf (SwitchTo tid) = rnf tid
  rnf d = d `seq` ()

-- | Get the resultant thread identifier of a 'Decision', with a default case
-- for 'Continue'.
tidOf
  :: t
  -- ^ The @Continue@ case.
  -> Decision t
  -- ^ The decision.
  -> t
tidOf _ (Start t)    = t
tidOf _ (SwitchTo t) = t
tidOf tid _          = tid

-- | Get the 'Decision' that would have resulted in this thread identifier,
-- given a prior thread (if any) and list of runnable threads.
decisionOf :: (Eq thread_id, Foldable f)
  => Maybe thread_id
  -- ^ The prior thread.
  -> f thread_id
  -- ^ The runnable threads.
  -> thread_id
  -- ^ The current thread.
  -> Decision thread_id
decisionOf Nothing _ chosen = Start chosen
decisionOf (Just prior) runnable chosen
  | prior == chosen = Continue
  | prior `elem` runnable = SwitchTo chosen
  | otherwise = Start chosen

-- | Get the tid of the currently active thread after executing a
-- series of decisions. The list MUST begin with a 'Start', if it
-- doesn't an error will be thrown.
activeTid ::
    [Decision thread_id]
  -- ^ The sequence of decisions that have been made.
  -> thread_id
activeTid (Start tid:ds) = foldl' tidOf tid ds
activeTid _ = error "activeTid: first decision MUST be a 'Start'."

-------------------------------------------------------------------------------
-- DPOR state

-- | DPOR execution is represented as a tree of states, characterised
-- by the decisions that lead to that state.
data DPOR thread_id thread_action = DPOR
  { dporRunnable :: Set thread_id
  -- ^ What threads are runnable at this step.
  , dporTodo     :: Map thread_id Bool
  -- ^ Follow-on decisions still to make, and whether that decision
  -- was added conservatively due to the bound.
  , dporDone     :: Map thread_id (DPOR thread_id thread_action)
  -- ^ Follow-on decisions that have been made.
  , dporSleep    :: Map thread_id thread_action
  -- ^ Transitions to ignore (in this node and children) until a
  -- dependent transition happens.
  , dporTaken    :: Map thread_id thread_action
  -- ^ Transitions which have been taken, excluding
  -- conservatively-added ones. This is used in implementing sleep
  -- sets.
  , dporAction   :: Maybe thread_action
  -- ^ What happened at this step. This will be 'Nothing' at the root,
  -- 'Just' everywhere else.
  }

instance ( NFData thread_id
         , NFData thread_action
         ) => NFData (DPOR thread_id thread_action) where
  rnf dpor = rnf ( dporRunnable dpor
                 , dporTodo     dpor
                 , dporDone     dpor
                 , dporSleep    dpor
                 , dporTaken    dpor
                 , dporAction   dpor
                 )

-- | Initial DPOR state, given an initial thread ID. This initial
-- thread should exist and be runnable at the start of execution.
initialState :: Ord thread_id => thread_id -> DPOR thread_id thread_action
initialState initialThread = DPOR
  { dporRunnable = S.singleton initialThread
  , dporTodo     = M.singleton initialThread False
  , dporDone     = M.empty
  , dporSleep    = M.empty
  , dporTaken    = M.empty
  , dporAction   = Nothing
  }

-- | Render a 'DPOR' value as a graph in GraphViz \"dot\" format.
toDot
  :: (thread_id -> String)
  -- ^ Show a @thread_id@ - this should produce a string suitable for
  -- use as a node identifier.
  -> (thread_action -> String)
  -- ^ Show a @thread_action@.
  -> DPOR thread_id thread_action
  -> String
toDot = toDotFiltered (\_ _ -> True)

-- | Render a 'DPOR' value as a graph in GraphViz \"dot\" format, with
-- a function to determine if a subtree should be included or not.
toDotFiltered
  :: (thread_id -> DPOR thread_id thread_action -> Bool)
  -- ^ Subtree predicate.
  -> (thread_id     -> String)
  -> (thread_action -> String)
  -> DPOR thread_id thread_action
  -> String
toDotFiltered check showTid showAct dpor = "digraph {\n" ++ go "L" dpor ++ "\n}" where
  go l b = unlines $ node l b : edges l b

  -- Display a labelled node.
  node n b = n ++ " [label=\"" ++ label b ++ "\"]"

  -- Display the edges.
  edges l b = [ edge l l' i ++ go l' b'
              | (i, b') <- M.toList (dporDone b)
              , check i b'
              , let l' = l ++ tidId i
              ]

  -- A node label, summary of the DPOR state at that node.
  label b = showLst id
    [ maybe "Nothing" (("Just " ++) . showAct) $ dporAction b
    , "Run:" ++ showLst showTid (S.toList $ dporRunnable b)
    , "Tod:" ++ showLst showTid (M.keys   $ dporTodo     b)
    , "Slp:" ++ showLst (\(t,a) -> "(" ++ showTid t ++ ", " ++ showAct a ++ ")")
        (M.toList $ dporSleep b)
    ]

  -- Display a labelled edge
  edge n1 n2 l = n1 ++ "-> " ++ n2 ++ " [label=\"" ++ showTid l ++ "\"]\n"

  -- Show a list of values
  showLst showf xs = "[" ++ intercalate ", " (map showf xs) ++ "]"

  -- Generate a graphviz-friendly identifier from a thread_id.
  tidId = concatMap (show . ord) . showTid
