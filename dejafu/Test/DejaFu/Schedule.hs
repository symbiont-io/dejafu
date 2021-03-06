-- |
-- Module      : Test.DejaFu.Schedule
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Maintainer  : Michael Walker <mike@barrucadu.co.uk>
-- Stability   : experimental
-- Portability : portable
--
-- Scheduling for concurrent computations.
module Test.DejaFu.Schedule
  ( -- * Scheduling
    Scheduler(..)

  , Decision(..)
  , tidOf
  , decisionOf

  , NonEmpty(..)

  -- ** Preemptive
  , randomSched
  , roundRobinSched

  -- ** Non-preemptive
  , randomSchedNP
  , roundRobinSchedNP

  -- * Utilities
  , makeNonPreemptive
  ) where

import           Data.List.NonEmpty (NonEmpty(..), toList)
import           System.Random      (RandomGen, randomR)

import           Test.DejaFu.Common

-- | A @Scheduler@ drives the execution of a concurrent program. The
-- parameters it takes are:
--
-- 1. The last thread executed (if this is the first invocation, this
--    is @Nothing@).
--
-- 2. The runnable threads at this point.
--
-- 3. The state.
--
-- It returns a thread to execute, or @Nothing@ if execution should
-- abort here, and also a new state.
--
-- @since 0.8.0.0
newtype Scheduler state = Scheduler
  { scheduleThread
    :: Maybe (ThreadId, ThreadAction)
    -> NonEmpty (ThreadId, Lookahead)
    -> state
    -> (Maybe ThreadId, state)
  }

-------------------------------------------------------------------------------
-- Scheduling decisions

-- | Get the resultant thread identifier of a 'Decision', with a default case
-- for 'Continue'.
--
-- @since 0.5.0.0
tidOf :: ThreadId -> Decision -> ThreadId
tidOf _ (Start t)    = t
tidOf _ (SwitchTo t) = t
tidOf tid _          = tid

-- | Get the 'Decision' that would have resulted in this thread identifier,
-- given a prior thread (if any) and list of runnable threads.
--
-- @since 0.5.0.0
decisionOf :: Foldable f
  => Maybe ThreadId
  -- ^ The prior thread.
  -> f ThreadId
  -- ^ The runnable threads.
  -> ThreadId
  -- ^ The current thread.
  -> Decision
decisionOf Nothing _ chosen = Start chosen
decisionOf (Just prior) runnable chosen
  | prior == chosen = Continue
  | prior `elem` runnable = SwitchTo chosen
  | otherwise = Start chosen

-------------------------------------------------------------------------------
-- Preemptive

-- | A simple random scheduler which, at every step, picks a random
-- thread to run.
--
-- @since 0.8.0.0
randomSched :: RandomGen g => Scheduler g
randomSched = Scheduler go where
  go _ threads g =
    let threads' = map fst (toList threads)
        (choice, g') = randomR (0, length threads' - 1) g
    in (Just $ threads' !! choice, g')

-- | A round-robin scheduler which, at every step, schedules the
-- thread with the next 'ThreadId'.
--
-- @since 0.8.0.0
roundRobinSched :: Scheduler ()
roundRobinSched = Scheduler go where
  go Nothing ((tid,_):|_) _ = (Just tid, ())
  go (Just (prior, _)) threads _ =
    let threads' = map fst (toList threads)
        candidates =
          if prior >= maximum threads'
          then threads'
          else filter (>prior) threads'
    in (Just (minimum candidates), ())

-------------------------------------------------------------------------------
-- Non-preemptive

-- | A random scheduler which doesn't preempt the running
-- thread. That is, if the last thread scheduled is still runnable,
-- run that, otherwise schedule randomly.
--
-- @since 0.8.0.0
randomSchedNP :: RandomGen g => Scheduler g
randomSchedNP = makeNonPreemptive randomSched

-- | A round-robin scheduler which doesn't preempt the running
-- thread.
--
-- @since 0.8.0.0
roundRobinSchedNP :: Scheduler ()
roundRobinSchedNP = makeNonPreemptive roundRobinSched

-------------------------------------------------------------------------------
-- Utilities

-- | Turn a potentially preemptive scheduler into a non-preemptive
-- one.
--
-- @since 0.8.0.0
makeNonPreemptive :: Scheduler s -> Scheduler s
makeNonPreemptive sched = Scheduler newsched where
  newsched p@(Just (prior, _)) threads s
    | prior `elem` map fst (toList threads) = (Just prior, s)
    | otherwise = scheduleThread sched p threads s
  newsched Nothing threads s = scheduleThread sched Nothing threads s
