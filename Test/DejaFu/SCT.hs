{-# LANGUAGE Rank2Types #-}

-- | Systematic testing for concurrent computations.
module Test.DejaFu.SCT
  ( -- * Bounded Partial-order Reduction

    -- | We can characterise the state of a concurrent computation by
    -- considering the ordering of dependent events. This is a partial
    -- order: independent events can be performed in any order without
    -- affecting the result, and so are /not/ ordered.
    --
    -- Partial-order reduction is a technique for computing these
    -- partial orders, and only testing one total order for each
    -- partial order. This cuts down the amount of work to be done
    -- significantly. /Bounded/ partial-order reduction is a further
    -- optimisation, which only considers schedules within some bound.
    --
    -- This module provides both a generic function for BPOR, and also
    -- a pre-emption bounding BPOR runner, which is used by the
    -- "Test.DejaFu" module.

    sctPreBound
  , sctPreBoundIO

  , BacktrackStep(..)
  , sctBounded
  , sctBoundedIO

  -- * Utilities
  , tidOf
  , tidTag
  , decisionOf
  , activeTid
  , preEmpCount
  , initialCVState
  , updateCVState
  , willBlock
  , willBlockSafely
  ) where

import Control.Applicative ((<$>), (<*>))
import Control.DeepSeq (force)
import Data.IntMap.Strict (IntMap)
import Data.Maybe (maybeToList, isNothing)
import Test.DejaFu.Deterministic
import Test.DejaFu.Deterministic.IO (ConcIO, runConcIO')
import Test.DejaFu.SCT.Internal

import qualified Data.IntMap.Strict as I
import qualified Data.Set as S

-- * Pre-emption bounding

-- | An SCT runner using a pre-emption bounding scheduler.
sctPreBound :: Int -> (forall t. Conc t a) -> [(Either Failure a, Trace)]
sctPreBound pb = sctBounded (pbBv pb) pbBacktrack pbInitialise

-- | Variant of 'sctPreBound' for computations which do 'IO'.
sctPreBoundIO :: Int -> (forall t. ConcIO t a) -> IO [(Either Failure a, Trace)]
sctPreBoundIO pb = sctBoundedIO (pbBv pb) pbBacktrack pbInitialise

-- | Check if a schedule is in the bound.
pbBv :: Int -> [Decision] -> Bool
pbBv pb ds = preEmpCount ds <= pb

-- | Add a backtrack point, and also conservatively add one prior to
-- the most recent transition before that point. This may result in
-- the same state being reached multiple times, but is needed because
-- of the artificial dependency imposed by the bound.
pbBacktrack :: [BacktrackStep] -> Int -> ThreadId -> [BacktrackStep]
pbBacktrack bs i tid = backtrack True (backtrack False bs i tid) (maximum js) tid where
  -- Index of the conservative point
  js = 0 : [ j
           | ((_,(t1,_)), (j,(t2,_))) <- pairs . zip [0..] $ tidTag (fst . _decision) 0 bs
           , t1 /= t2
           , j < i
           ]

  {-# INLINE pairs #-}
  pairs = zip <*> tail

  -- Add a backtracking point. If the thread isn't runnable, add all
  -- runnable threads.
  backtrack c bx@(b:bs) 0 t
    -- If the backtracking point is already present, don't re-add it,
    -- UNLESS this would force it to backtrack (it's conservative)
    -- where before it might not.
    | t `S.member` _runnable b =
      let val = I.lookup t $ _backtrack b
      in  if isNothing val || (val == Just False && c)
          then b { _backtrack = I.insert t c $ _backtrack b } : bs
          else bx

    -- Otherwise just backtrack to everything runnable.
    | otherwise = b { _backtrack = I.fromList [ (t,c) | t <- S.toList $ _runnable b ] } : bs

  backtrack c (b:bs) n t = b : backtrack c bs (n-1) t
  backtrack _ [] _ _ = error "Ran out of schedule whilst backtracking!"

-- | Pick a new thread to run. Choose the current thread if available,
-- otherwise add all runnable threads.
pbInitialise :: Maybe (ThreadId, a) -> NonEmpty (ThreadId, b) -> NonEmpty ThreadId
pbInitialise prior threads@((next, _):|rest) = case prior of
  Just (tid, _)
    | any (\(t, _) -> t == tid) $ toList threads -> tid:|[]
  _ -> next:|map fst rest

-- * BPOR

-- | SCT via BPOR.
--
-- Schedules are generated by running the computation with a
-- deterministic scheduler with some initial list of decisions, after
-- which the supplied function is called. At each step of execution,
-- possible-conflicting actions are looked for, if any are found,
-- \"backtracking points\" are added, to cause the events to happen in
-- a different order in a future execution.
--
-- Note that unlike with non-bounded partial-order reduction, this may
-- do some redundant work as the introduction of a bound can make
-- previously non-interfering events interfere with each other.
sctBounded :: ([Decision] -> Bool)
           -- ^ Check if a prefix trace is within the bound.
           -> ([BacktrackStep] -> Int -> ThreadId -> [BacktrackStep])
           -- ^ Add a new backtrack point, this takes the history of
           -- the execution so far, the index to insert the
           -- backtracking point, and the thread to backtrack to. This
           -- may insert more than one backtracking point.
           -> (Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, ThreadAction') -> NonEmpty ThreadId)
           -- ^ Produce possible scheduling decisions, all will be
           -- tried.
           -> (forall t. Conc t a) -> [(Either Failure a, Trace)]
sctBounded bv backtrack initialise c = go initialState where
  go bpor = case next bpor of
    Just (sched, conservative, bpor') ->
      -- Run the computation
      let (res, s, trace) = runConc' (bporSched initialise) (initialSchedState sched) c
      -- Identify the backtracking points
          bpoints = findBacktrack backtrack (_sbpoints s) trace
      -- Add new nodes to the tree
          bpor''  = grow conservative trace bpor'
      -- Add new backtracking information
          bpor''' = todo bv bpoints bpor''
      -- Loop
      in (res, toTrace trace) : go bpor'''

    Nothing -> []

-- | Variant of 'sctBounded' for computations which do 'IO'.
sctBoundedIO :: ([Decision] -> Bool)
             -> ([BacktrackStep] -> Int -> ThreadId -> [BacktrackStep])
             -> (Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, ThreadAction') -> NonEmpty ThreadId)
             -> (forall t. ConcIO t a) -> IO [(Either Failure a, Trace)]
sctBoundedIO bv backtrack initialise c = go initialState where
  go bpor = case next bpor of
    Just (sched, conservative, bpor') -> do
      (res, s, trace) <- runConcIO' (bporSched initialise) (initialSchedState sched) c

      let bpoints = findBacktrack backtrack (_sbpoints s) trace
      let bpor''  = grow conservative trace bpor'
      let bpor''' = todo bv bpoints bpor''

      ((res, toTrace trace):) <$> go bpor'''

    Nothing -> return []

-- * BPOR Scheduler

-- | The scheduler state
data SchedState = SchedState
  { _sprefix  :: [ThreadId]
  -- ^ Decisions still to make
  , _sbpoints :: [(NonEmpty (ThreadId, ThreadAction'), [ThreadId])]
  -- ^ Which threads are runnable at each step, and the alternative
  -- decisions still to make.
  , _scvstate :: IntMap Bool
  -- ^ The 'CVar' block state.
  }

-- | Initial scheduler state for a given prefix
initialSchedState :: [ThreadId] -> SchedState
initialSchedState prefix = SchedState
  { _sprefix  = prefix
  , _sbpoints = []
  , _scvstate = initialCVState
  }

-- | BPOR scheduler: takes a list of decisions, and maintains a trace
-- including the runnable threads, and the alternative choices allowed
-- by the bound-specific initialise function.
bporSched :: (Maybe (ThreadId, ThreadAction) -> NonEmpty (ThreadId, ThreadAction') -> NonEmpty ThreadId)
          -> Scheduler SchedState
bporSched initialise = force $ \s prior threads -> case _sprefix s of
  -- If there is a decision available, make it
  (d:ds) ->
    let threads' = fmap (\(t,a:|_) -> (t,a)) threads
        cvstate' = maybe (_scvstate s) (updateCVState (_scvstate s) . snd) prior
    in  (d, s { _sprefix = ds, _sbpoints = _sbpoints s ++ [(threads', [])], _scvstate = cvstate' })

  -- Otherwise query the initialise function for a list of possible
  -- choices, and make one of them arbitrarily (recording the others).
  [] ->
    let threads' = fmap (\(t,a:|_) -> (t,a)) threads
        choices  = initialise prior threads'
        cvstate' = maybe (_scvstate s) (updateCVState (_scvstate s) . snd) prior
        choices' = [t
                   | t  <- toList choices
                   , as <- maybeToList $ lookup t (toList threads)
                   , not . willBlockSafely cvstate' $ toList as
                   ]
    in  case choices' of
          (next:rest) -> (next, s { _sbpoints = _sbpoints s ++ [(threads', rest)], _scvstate = cvstate' })

          -- TODO: abort the execution here.
          [] -> case choices of
                 (next:|_) -> (next, s { _sbpoints = _sbpoints s ++ [(threads', [])], _scvstate = cvstate' })
