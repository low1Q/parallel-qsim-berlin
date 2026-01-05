package org.matsim.routing.router;

import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.api.core.v01.population.Person;
import org.matsim.core.router.util.TravelTime;
import org.matsim.vehicles.Vehicle;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

public class TravelTimeSnapshot implements TravelTime {

    // Eine kleine Hilfsklasse für den Snapshot
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
    private final Map<Id<Link>, Integer> linkIdToIndex;
    private int versionCounter = 0;

    public TravelTimeSnapshot(Network network) {
        this.linkIdToIndex = new HashMap<>();
        double[] initialTimes = new double[network.getLinks().size()];

        int i = 0;
        for (Link link : network.getLinks().values()) {
            linkIdToIndex.put(link.getId(), i);
            // Initialzustand: Free-Speed (Länge / Geschwindigkeit)
            initialTimes[i] = link.getLength() / link.getFreespeed();
            i++;
        }
        this.currentSnapshot = new AtomicReference<>(new Snapshot(initialTimes, versionCounter++));
    }

    // Gibt das aktuellste Array aus dem Snapshot zurück
    public double[] getCurrentTimesArray() {
        return currentSnapshot.get().times;
    }

    // Ermöglicht den Zugriff auf die Index-Map
    public Map<Id<Link>, Integer> getLinkIdToIndex() {
        return this.linkIdToIndex;
    }

    // Hilfsmethode für den UpdatingService: Akzeptiert ein fertig vorbereitetes Array
    public void updateWithArray(double[] newTimes) {
        Snapshot old = currentSnapshot.get();
        // Wir erhöhen die Version und setzen das neue Array atomar
        currentSnapshot.set(new Snapshot(newTimes, old.version + 1));
    }

    /**
     * Liefert eine TravelTime-Sicht, die sich nie ändert (Free-Speed).
     * Wird genutzt, um SpeedyALT-Landmarken einmalig stabil zu berechnen.
     */
    public TravelTime getStaticFreeSpeedView() {
        return new TravelTime() {
            @Override
            public double getLinkTravelTime(Link link, double time, Person person, Vehicle vehicle) {
                return link.getLength() / link.getFreespeed();
            }
        };
    }

    @Override
    public double getLinkTravelTime(Link link, double time, Person person, Vehicle vehicle) {
        // Extrem schnell: Nur eine Referenz holen
        return currentSnapshot.get().times[linkIdToIndex.get(link.getId())];
    }

    public void updateTravelTimes(Map<Id<Link>, Double> updates) {
        Snapshot old = currentSnapshot.get();
        double[] newTimes = old.times.clone();

        updates.forEach((id, val) -> {
            Integer idx = linkIdToIndex.get(id);
            if (idx != null) newTimes[idx] = val;
        });

        Snapshot next = new Snapshot(newTimes, versionCounter++);
        currentSnapshot.set(next);

        System.out.println("Snapshot aktualisiert auf Version " + next.version +
                " um " + new java.util.Date(next.timestamp));
    }
}