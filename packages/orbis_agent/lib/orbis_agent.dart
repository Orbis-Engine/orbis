/// What moves things that decide for themselves.
///
/// Two halves that meet at the agent. Steering answers "which way, and how
/// hard" — a set of small forces that are added together rather than chosen
/// between, because an agent that picked one reason to move per frame snaps
/// between them and the snap is visible however good each reason is.
/// Behaviour trees answer "what should it be trying to do" — and their whole
/// point is the third status: a node that is still working and wants asking
/// again, without which nothing can walk anywhere or wait for anything.
///
/// Neither half knows about the other, and neither knows about the renderer.
/// A steering force is a vector and a tree leaf is a closure, so the same
/// patrol tree drives a guard in a scene, a cursor in a test, and a dot in a
/// diagram.
library;

export 'src/behaviour.dart'
    show
        Act,
        Brain,
        Check,
        Cooldown,
        Deadline,
        Do,
        Invert,
        Memory,
        Node,
        Parallel,
        Repeat,
        Selector,
        Sequence,
        Status,
        Succeed,
        Tick,
        Wait;
export 'src/steering.dart'
    show
        Align,
        Arrive,
        Blend,
        Cohere,
        Evade,
        Flee,
        FollowPath,
        Pursue,
        Seek,
        Separate,
        Steerable,
        Steering,
        Wander;
