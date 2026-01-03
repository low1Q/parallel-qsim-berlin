package org.matsim.routing.router;

import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.api.core.v01.population.Person;
import org.matsim.core.router.util.TravelTime;
import org.matsim.vehicles.Vehicle;

import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Hochperformante TravelTime-Implementierung für gRPC-Szenarien.
 * Optimiert für Millionen von Abfragen pro Sekunde durch Vermeidung von Map-Lookups via Id-Objekten.
 */
public class TravelTimeSnapshot implements TravelTime {

    private static class Snapshot {
        final double[] times;
        final long timestamp;
        final int version;

        Snapshot(double[] times, int version) {
            this.times = times;
            this.version = version;
            this.timestamp = System.currentTimeMillis();
        }
    }

    private final AtomicReference<Snapshot> currentSnapshot;

    // Für den Router: Schnellster Zugriff via Speicheradresse (== statt .equals())
    private final Map<Link, Integer> linkToInternalIndex;

    // Für den UpdatingService: Zugriff via String-ID
    private final Map<String, Integer> stringIdToIndex;

    private final AtomicInteger versionCounter = new AtomicInteger(0);

    public TravelTimeSnapshot(Network network, List<String> linkIdsFromRust) {
        int size = linkIdsFromRust.size();
        double[] initialTimes = new double[size];

        this.linkToInternalIndex = new IdentityHashMap<>(size);
        this.stringIdToIndex = new HashMap<>(size);

        for (int i = 0; i < size; i++) {
            String extId = linkIdsFromRust.get(i);
            Id<Link> mId = Id.createLinkId(extId);
            Link link = network.getLinks().get(mId);

            if (link != null) {
                // Der Index i kommt direkt aus der Reihenfolge der Rust-Liste
                linkToInternalIndex.put(link, i);
                stringIdToIndex.put(extId, i);
                initialTimes[i] = link.getLength() / link.getFreespeed();
            }
        }
        this.currentSnapshot = new AtomicReference<>(new Snapshot(initialTimes, 0));
    }

    @Override
    public double getLinkTravelTime(Link link, double time, Person person, Vehicle vehicle) {
        // DER TURBO-PFAD:
        // 1. IdentityHashMap-Lookup ist O(1) und nutzt nur Objektreferenzen (kein hashCode/equals von IDs)
        // 2. Direkter Zugriff auf das primitive double-Array im aktuellen Snapshot
        return currentSnapshot.get().times[linkToInternalIndex.get(link)];
    }

    // Der Updater nutzt direkt den Index aus der Proto-Nachricht:
    public double getLinkTravelTimeByIndex(int linkIdx) {
        return currentSnapshot.get().times[linkIdx];
    }

    /**
     * Wird vom UpdatingService aufgerufen.
     * Erzeugt atomar einen neuen Snapshot mit Timestamp und Version.
     */
    public void updateWithArray(double[] newTimes) {
        // Wir setzen das neue Array atomar und erhöhen die Version
        currentSnapshot.set(new Snapshot(newTimes, versionCounter.incrementAndGet()));
    }

    /**
     * Ermöglicht dem UpdatingService, den internen Index für eine String-ID zu finden.
     */
    public Map<String, Integer> getStringIdToIndex() {
        return this.stringIdToIndex;
    }

    public long getLastUpdateTimestamp() {
        return currentSnapshot.get().timestamp;
    }

    public int getCurrentVersion() {
        return currentSnapshot.get().version;
    }

    /**
     * Statische Sicht für Speedy-Landmarken-Berechnung.
     */
    public TravelTime getStaticFreeSpeedView() {
        return (link, time, person, vehicle) -> link.getLength() / link.getFreespeed();
    }
}