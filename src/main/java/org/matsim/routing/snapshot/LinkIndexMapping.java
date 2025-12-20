package org.matsim.routing.snapshot;

import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;

import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

/**
 * Immutable mapping from Link Id to dense integer index.
 */
public final class LinkIndexMapping {

    private final Map<Id<Link>, Integer> linkId2Index;
    private final int size;

    public LinkIndexMapping(Network network) {
        Objects.requireNonNull(network);
        this.linkId2Index = new HashMap<>(network.getLinks().size());
        int idx = 0;
        for (Link link : network.getLinks().values()) {
            linkId2Index.put(link.getId(), idx++);
        }
        this.size = idx;
    }

    public int getIndex(Link link) {
        Integer idx = linkId2Index.get(link.getId());
        if (idx == null) {
            throw new IllegalArgumentException("Unknown link: " + link.getId());
        }
        return idx;
    }

    public int size() {
        return size;
    }
}
