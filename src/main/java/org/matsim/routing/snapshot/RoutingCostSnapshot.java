package org.matsim.routing.snapshot;

import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.router.util.TravelTime;

/**
 * Immutable container holding TravelTime and TravelDisutility snapshots that belong together.
 */
public final class RoutingCostSnapshot {
    public final TravelTime travelTime;
    public final TravelDisutility travelDisutility;

    public RoutingCostSnapshot(TravelTime travelTime, TravelDisutility travelDisutility) {
        this.travelTime = travelTime;
        this.travelDisutility = travelDisutility;
    }
}
