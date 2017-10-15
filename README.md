# rndds

## Overview

rndds is a distributed application where a fixed set of peers periodically sends a random
number between 0 and 1 to all other peers. All messages are ordered using
Lamport Timestamps. Sending of new messages stops after a set time (-k argument), and
the application waits an additional time (-l argument) for outstanding messages. When
exiting each peers prints the timestamp and the random value they received in transmission
order.

At the start all peers can talk to each other, but connectivity between some
(or possibly all after a while) peers is expected to fail. The cluster will attempt to
overcome this by utilizing a Probabilistic Reliable Multicast scheme, as presented
by Jun Luo, Patrick Th and Eugster Jean-pierre Hubaux in Probabilistic Reliable Multicast
published in Ad Hoc Networks (Ad Hoc Networks 2 2004 volume 2.)

rndds uses TCP as transport protocol. For TCP sockets the 'distributed-process'
package provides unreliable in order delivery messages. This is not ideal, instead
a transport layer on top of UDP would be preferable. With an UDP transport rndds could
detect missing packets directly and start asking other peers for it.

The broadcasted stream of random values is deterministic and based on a seed
(-s argument). The peer's 'gossip' functionality is also seeded with values derived from
the provided seed, but not completely deterministic. The 'gossip' functionality should
differ between the nodes which has the effect that changing the number of nodes will
result in different gossip being sent. The 'gossip' functionality also depends on
timing of network events.


## Building
stack build

## Run
rndds uses distributed-process-simplelocalnet to find the initial set of peers.
Each peer is started in slave mode, and a master node is used to distribute
configuration and start the broadcasting.

1. Start the slaves
   For each slave do:
     * stack exec rndds-exe -- -h <ip address to use> -p <port to use>
     * stack exec rndds-exe -- -h <ip address to use> -p <another port to use>
2. Start the master, and run for 180s.
   stack exec rndds-exe -- -m -k180

The test directory contains the script simple.sh which can be used to start
10 peers on the local computer. After completion the script verifies that all peers
agree on ordering and value of the random numbers sent between them.
