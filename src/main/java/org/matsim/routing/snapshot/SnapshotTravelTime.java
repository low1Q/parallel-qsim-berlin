package org.matsim.routing.snapshot;

import org.matsim.api.core.v01.network.Link;
import org.matsim.core.router.util.TravelTime;
import org.matsim.api.core.v01.population.Person;
import org.matsim.vehicles.Vehicle;

/**
 * Immutable snapshot implementation of TravelTime backed by an array.
 */
public final class SnapshotTravelTime implements TravelTime {

    private final double[] ttPerLink;
    private final LinkIndexMapping linkIndex;

    public SnapshotTravelTime(double[] ttPerLink, LinkIndexMapping linkIndex) {
        this.ttPerLink = ttPerLink;
        this.linkIndex = linkIndex;
    }

    @Override
    public double getLinkTravelTime(Link link, double time, Person person, Vehicle vehicle) {
        return ttPerLink[linkIndex.getIndex(link)];
    }
}
