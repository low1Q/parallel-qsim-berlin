package org.matsim.routing.snapshot;

import org.matsim.api.core.v01.network.Link;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.api.core.v01.population.Person;
import org.matsim.vehicles.Vehicle;

/**
 * Immutable snapshot implementation of TravelDisutility backed by an array.
 */
public final class SnapshotTravelDisutility implements TravelDisutility {

    private final double[] costPerLink;
    private final LinkIndexMapping linkIndex;

    public SnapshotTravelDisutility(double[] costPerLink, LinkIndexMapping linkIndex) {
        this.costPerLink = costPerLink;
        this.linkIndex = linkIndex;
    }

    @Override
    public double getLinkTravelDisutility(Link link, double time, Person person, Vehicle vehicle) {
        return costPerLink[linkIndex.getIndex(link)];
    }

    @Override
    public double getLinkMinimumTravelDisutility(Link link) {
        return costPerLink[linkIndex.getIndex(link)];
    }
}
