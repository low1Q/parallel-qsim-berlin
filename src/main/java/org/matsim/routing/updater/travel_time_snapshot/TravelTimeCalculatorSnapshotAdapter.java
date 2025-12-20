package org.matsim.routing.updater.travel_time_snapshot;

import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.core.router.util.TravelTime;
import org.matsim.core.trafficmonitoring.TravelTimeCalculator;

import java.util.concurrent.atomic.AtomicReference;

/**
 * Adapter between MATSim TravelTimeCalculator (single-writer)
 * and immutable TravelTime snapshots (multi-reader).
 */
public final class TravelTimeCalculatorSnapshotAdapter {

    private final TravelTimeCalculator ttc;
    private final Network network;
    private final LinkIndexMapping linkIndex;
    private final AtomicReference<TravelTime> snapshotRef;

    public TravelTimeCalculatorSnapshotAdapter(
            TravelTimeCalculator ttc,
            Network network
    ) {
        this.ttc = ttc;
        this.network = network;
        this.linkIndex = new LinkIndexMapping(network);
        this.snapshotRef = new AtomicReference<>();
    }

    /**
     * Build and atomically swap a new TravelTime snapshot.
     * Must be called from the updater thread only.
     */
    public void buildAndSwapSnapshot(double time) {

        final double[] ttPerLink = new double[linkIndex.size()];
        final TravelTime source = ttc.getLinkTravelTimes();

        for (Link link : network.getLinks().values()) {
            int idx = linkIndex.getIndex(link);
            ttPerLink[idx] = source.getLinkTravelTime(link, time, null, null);
        }

        snapshotRef.set(new SnapshotTravelTime(ttPerLink, linkIndex));
    }

    /**
     * Lock-free access for routing threads.
     */
    public TravelTime getSnapshot() {
        return snapshotRef.get();
    }
}
