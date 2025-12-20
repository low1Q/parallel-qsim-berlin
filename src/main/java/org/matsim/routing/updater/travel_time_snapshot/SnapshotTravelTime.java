package org.matsim.routing.updater.travel_time_snapshot;

import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.population.Person;
import org.matsim.core.router.util.TravelTime;
import org.matsim.vehicles.Vehicle;

/**
 * Immutable, thread-safe TravelTime snapshot.
 */
final class SnapshotTravelTime implements TravelTime {

    private final double[] ttPerLink;
    private final LinkIndexMapping linkIndex;

    SnapshotTravelTime(double[] ttPerLink, LinkIndexMapping linkIndex) {
        this.ttPerLink = ttPerLink;
        this.linkIndex = linkIndex;
    }

    @Override
    public double getLinkTravelTime(
            Link link,
            double time,
            Person person,
            Vehicle vehicle
    ) {
        return ttPerLink[linkIndex.getIndex(link)];
    }
}
