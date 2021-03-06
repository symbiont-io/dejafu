dejafu
======

> [Déjà Fu is] A martial art in which the user's limbs move in time as
> well as space, […] It is best described as "the feeling that you
> have been kicked in the head this way before"
>
> -- Terry Pratchett, Thief of Time

Concurrency is nice, deadlocks and race conditions not so much. The
`Par` monad family, as defined in [abstract-par][] provides
deterministic parallelism, but sometimes we can tolerate a bit of
nondeterminism.

This package builds on the concurrency package (also in this
repository) by enabling you to systematically and deterministically
test your concurrent programs.

The documentation of the latest developmental version is
[available online][docs]. Examples can be found in the test suite.

**Note on the test suite:** This is in a separate project
(dejafu-tests) because Cabal-the-library is a bit naff. See this
[issue][].

Déjà Fu and `IO`
----------------

The core assumption underlying Déjà Fu is that any apparent
nondeterminism arises purely from the scheduling behaviour. To put it
another way, a given computation, parametrised with a fixed set of
scheduling decisions, is deterministic.

Whilst this assumption may not hold in general when `IO` is involved,
you should strive to produce test cases where it does.

Memory Model
------------

The testing functionality supports a few different memory models, for
computations which use non-synchronised `CRef` operations. The
supported models are:

- **Sequential Consistency:** A program behaves as a simple
    interleaving of the actions in different threads. When a CRef is
    written to, that write is immediately visible to all threads.

- **Total Store Order (TSO):** Each thread has a write buffer. A
    thread sees its writes immediately, but other threads will only
    see writes when they are committed, which may happen later. Writes
    are committed in the same order that they are created.

- **Partial Store Order (PSO):** Each CRef has a write buffer. A
    thread sees its writes immediately, but other threads will only
    see writes when they are committed, which may happen later. Writes
    to different CRefs are not necessarily committed in the same order
    that they are created.

If a testing function does not take the memory model as a parameter,
it uses TSO.

Contributing
------------

Bug reports, pull requests, and comments are very welcome!

Feel free to contact me on GitHub, through IRC (#haskell on freenode),
or email (mike@barrucadu.co.uk).

[docs]:         https://docs.barrucadu.co.uk/dejafu
[abstract-par]: https://hackage.haskell.org/package/abstract-par/docs/Control-Monad-Par-Class.html
[issue]:        https://github.com/commercialhaskell/stack/issues/1122
