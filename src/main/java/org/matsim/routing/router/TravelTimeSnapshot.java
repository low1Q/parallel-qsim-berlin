package org.matsim.routing.router;

import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.network.Link;
import org.matsim.api.core.v01.network.Network;
import org.matsim.api.core.v01.population.Person;
import org.matsim.core.router.util.TravelTime;
import org.matsim.vehicles.Vehicle;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentNavigableMap;
import java.util.concurrent.ConcurrentSkipListMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * TravelTimeSnapshot ist eine TravelTime-Implementierung, die Link-Reisezeiten als double[] speichert.
 * <p>
 * Problem (vorher):
 * - Routing läuft parallel.
 * - Updates publizieren neue Snapshots.
 * - Während EINER Routenberechnung können mehrere getLinkTravelTime(...) Calls passieren.
 * - Wenn zwischen diesen Calls ein neuer Snapshot veröffentlicht wird, sieht die Route inkonsistente Werte.
 * <p>
 * Lösung (jetzt):
 * 1) Updates publizieren weiterhin atomar einen neuen Snapshot (publish/swap).
 * 2) Zusätzlich behalten wir Snapshots pro Zeitfenster (TripBin / BinStart) in einer kleinen History.
 * 3) Pro Routing-Request "binden" wir einmalig den passenden Snapshot an den aktuellen Thread (ThreadLocal),
 * sodass alle getLinkTravelTime(...) Aufrufe innerhalb dieser Anfrage konsistent denselben Snapshot nutzen.
 * <p>
 * Wichtig:
 * - Nach dem Publish werden Snapshot-Arrays NIE mehr verändert ("publish-and-never-mutate").
 * - Mehrere Routing-Threads dürfen gleichzeitig aus demselben Snapshot lesen → thread-safe & lockfrei im Hot-Path.
 * -Für Determinismus wird NICHT mehr auf den "nächstbesten" älteren Snapshot zurückgefallen.
 * Falls der deterministisch benötigte Snapshot noch nicht existiert, blockiert bindToTime(...),
 * bis genau dieser Snapshot publiziert wurde.
 */
public class TravelTimeSnapshot implements TravelTime {

    /**
     * Interner Snapshot: immutable Container.
     * times[] wird nach Veröffentlichung niemals mehr verändert.
     */
    private record Snapshot(double[] times, long id, double timestamp) {
    }

    private static final Logger log = LogManager.getLogger(TravelTimeSnapshot.class);

    // Default-Bin-Größe: 900 Sekunden = 15 Minuten (TravelTimeCalculator default)
    public static final long DEFAULT_WINDOW_SIZE_SECONDS = 900L;
    public static final int BIN_LAG = 2;

    /**
     * Bin-Größe (z.B. 900s). Konfigurierbar über Konstruktor.
     */
    private final long windowSizeSeconds;

    /**
     * Aktueller Snapshot (atomar ausgetauscht).
     * Routing ohne Binding würde bei jedem Call currentSnapshot.get() lesen (→ kann wechseln).
     */
    private final AtomicReference<Snapshot> currentSnapshot;

    /**
     * Sequenzgenerator für Snapshot-IDs (monoton steigend).
     */
    private final AtomicLong snapshotSeq = new AtomicLong(0);

    /**
     * Map LinkId -> ArrayIndex (einmalig aufgebaut).
     */
    private final Map<Id<Link>, Integer> linkIdToIndex;

    /**
     * Zeitindizierte History: BinStart (Sekunden) -> Snapshot.
     * <p>
     * Warum ConcurrentNavigableMap?
     * - Updates: 1 Thread schreibt (dein updaterExecutor ist single-threaded)
     * - Routing: viele Threads lesen beim BINDEN (nur 1x pro Request).
     * - NavigableMap erlaubt floorEntry(...) für robustes "nimm Snapshot bis zu diesem Zeitpunkt".
     * <p>
     * Performance:
     * - getLinkTravelTime(...) (Hot Path) nutzt NICHT diese Map, sondern boundTimes ThreadLocal.
     * - Die Map wird nur beim Publish und beim Bind benutzt.
     */
    private final ConcurrentNavigableMap<Long, Snapshot> snapshotsByBinStart =
            new ConcurrentSkipListMap<>();

    /**
     * Per Thread gebundene Snapshot-Sicht (für konsistentes Routing).
     * Wenn gesetzt, liest getLinkTravelTime(...) immer aus diesem Array.
     */
    private final ThreadLocal<double[]> boundTimes = new ThreadLocal<>();

    /**
     * Per Thread gebundene Snapshot-ID (für Debug/Verifikation).
     */
    private final ThreadLocal<Long> boundSnapshotId = new ThreadLocal<>();

    /**
     * Per Thread gebundener Snapshot-Timestamp (für Debug/Verifikation).
     */
    private final ThreadLocal<Double> boundSnapshotTimestamp = new ThreadLocal<>();

    /**
     * Monitor für blockierendes Warten, bis ein deterministisch benötigter Snapshot publiziert wurde.
     */
    private final Object snapshotMonitor = new Object();

    /**
     * Optional: gemessene Gesamt-Wartezeit aller Routing-Threads in Nanosekunden.
     * Nützlich für die Evaluation.
     */
    private final AtomicLong totalWaitTimeNanos = new AtomicLong(0L);

    /**
     * Optional: Anzahl der Wait-Vorgänge.
     */
    private final AtomicLong totalWaitCount = new AtomicLong(0L);

    /**
     * Default-Konstruktor: windowSizeSeconds = 900s.
     */
    public TravelTimeSnapshot(Network network) {
        this(network, DEFAULT_WINDOW_SIZE_SECONDS);
    }

    /**
     * Konfigurierbarer Konstruktor.
     *
     * @param windowSizeSeconds Größe eines Zeitfensters in Sekunden (z.B. 900)
     */
    public TravelTimeSnapshot(Network network, long windowSizeSeconds) {
        if (windowSizeSeconds <= 0) {
            throw new IllegalArgumentException("windowSizeSeconds must be > 0");
        }
        this.windowSizeSeconds = windowSizeSeconds;

        this.linkIdToIndex = new HashMap<>();
        double[] initialTimes = new double[network.getLinks().size()];

        int i = 0;
        for (Link link : network.getLinks().values()) {
            linkIdToIndex.put(link.getId(), i);

            // Initialzustand: Free-Speed (Länge / Geschwindigkeit)
            initialTimes[i] = link.getLength() / link.getFreespeed();
            i++;
        }

        long id = snapshotSeq.incrementAndGet();
        Snapshot init = new Snapshot(initialTimes, id, 0.0);

        this.currentSnapshot = new AtomicReference<>(init);

        // Initialer Snapshot gilt ab Zeit 0
        snapshotsByBinStart.put(0L, init);
    }

    /**
     * Hilfsfunktion: liefert den Start des Bins (z.B. 15min-Fenster) zu einer Zeit.
     * Beispiel: window=900, time=960 → binStart=900 (Fenster [900,1800[)
     */
    private long binStart(double timeSeconds) {
        long t = (long) Math.floor(timeSeconds);
        return (t / windowSizeSeconds) * windowSizeSeconds;
    }

    /**
     * @return das aktuellste Times-Array (Achtung: nur lesen, nie verändern!).
     */
    public double[] getCurrentTimesArray() {
        return currentSnapshot.get().times;
    }

    /**
     * @return Mapping LinkId -> ArrayIndex.
     */
    public Map<Id<Link>, Integer> getLinkIdToIndex() {
        return this.linkIdToIndex;
    }

    /**
     * Publiziert einen neuen Snapshot und speichert ihn in der History für das Zeitfenster,
     * das zu nowSeconds passt.
     * <p>
     * Wichtig:
     * - newTimes MUSS ein neues Array sein (oder ein clone), das anschließend nicht mehr verändert wird.
     * Unser UpdatingService macht dafür internalTravelTimes.clone().
     *
     * @param newTimes   neues (immutable) Times-Array
     * @param nowSeconds Zeit (in Sekunden), zu der dieser Snapshot gilt (Request.now aus Events/Batch)
     * @return Snapshot-ID (für Logging/Debug)
     */
    public long updateWithArray(double[] newTimes, double nowSeconds) {
        long id = snapshotSeq.incrementAndGet();
        Snapshot snap = new Snapshot(newTimes, id, nowSeconds);

        // Atomar "current" ersetzen
        currentSnapshot.set(snap);

        // Zusätzlich in der History unter dem passenden Bin speichern
        long bin = binStart(nowSeconds);
        synchronized (snapshotMonitor) {
            snapshotsByBinStart.put(bin, snap);
            snapshotMonitor.notifyAll();
        }
        //log.info("History: {}", snapshotsByBinStart);

        return id;
    }

    /**
     * Bindet den Snapshot passend zu einer Zeit an den aktuellen Thread.
     * <p>
     * Für unser Setup:
     * Binde nach request.now (= rt) (ggf. departure_time (= dt)?).
     * <p>
     * // * Auswahlregel:
     * //* - wir nehmen den Snapshot für den Bin ≤ timeSeconds (floorEntry),
     * //* - falls keiner existiert, fallback currentSnapshot.
     * Auswahlregel (konsistent, deterministisch, robust gegen Race Conditions):
     * Wir binden NICHT den Snapshot des aktuellen Bins, sondern immer den Snapshot des vorherigen Bins
     * ("one-bin lag"), d.h. targetBin = binStart(timeSeconds) - windowSizeSeconds.
     * Wenn dieser Snapshot noch nicht publiziert wurde (Race Condition), nehmen wir den aktuellsten Snapshot,
     * der bis targetBin verfügbar ist (floorEntry).
     * Falls es gar keine History gibt, fallback auf initialen currentSnapshot.
     *
     * @param timeSeconds Zeit, zu der geroutet wird (bei uns grade request.now)
     *                    <p>
     *                    Bindet den deterministisch korrekten Snapshot an den aktuellen Thread.
     *                    <p>
     *                    Semantik:
     *                    - currentBin = binStart(timeSeconds)
     *                    - wegen one-bin: lag wird targetBin = currentBin - windowSizeSeconds verwendet
     *                    - falls dieser Snapshot noch nicht existiert, wird BLOCKIERT, bis er publiziert wurde
     *                    <p>
     *                    Es gibt bewusst KEINEN stillen Fallback mehr auf floorEntry(...), weil das den
     *                    Determinismus verletzen könnte.
     */

    public boolean bindToTime(double timeSeconds) {
        long currentBin = binStart(timeSeconds);
        // Immer zwei Bins davor routen.
        long targetBin = currentBin - BIN_LAG * windowSizeSeconds;
        if (targetBin < 0) {
            targetBin = 0;
        }

        Snapshot snap;
        boolean hadToWait = false;
        synchronized (snapshotMonitor) {
            while ((snap = snapshotsByBinStart.get(targetBin)) == null) {
                hadToWait = true;
//                log.info("Routingrequest für now: {} und departureTime: {} aus Thread {} wartet auf Time-Bin {}", timeSeconds, request.getDepartureTime(),threadName, targetBin);
//                log.info("Queue stats: size: {}, activeThreads: {}, completedTasks: {}, totalTasks: {}", size, activeCount, completedTaskCount, taskCount);
                try {
                    snapshotMonitor.wait();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new RuntimeException(
                            "Interrupted while waiting for snapshot for bin " + targetBin, e);
                }
            }
        }
        boundTimes.set(snap.times);
        boundSnapshotId.set(snap.id);
        boundSnapshotTimestamp.set(snap.timestamp);
        return hadToWait;
    }

    /**
     * Entfernt die Bindung am Thread.
     * Muss IMMER im finally passieren, sonst bleibt im Worker-Thread ein alter Snapshot gebunden.
     */
    public void unbind() {
        boundTimes.remove();
        boundSnapshotId.remove();
        boundSnapshotTimestamp.remove();
    }

    /**
     * Debug: @return gebundene Snapshot-ID oder -1, wenn ungebunden.
     */
    public long getBoundSnapshotId() {
        Long id = boundSnapshotId.get();
        return id != null ? id : -1L;
    }

    /**
     * Debug: @return aktuell publizierte Snapshot-ID (unabhängig vom Binding).
     */
    public long getCurrentSnapshotId() {
        return currentSnapshot.get().id;
    }

    /**
     * Debug: @return aktuell publizierte Snapshot-Timestamp (unabhängig vom Binding).
     */
    public double getCurrentSnapshotTimestamp() {
        return currentSnapshot.get().timestamp;
    }

    /**
     * Debug: @return Zeit (Sekunden), ab der der gebundene Snapshot gilt, oder NaN wenn ungebunden.
     */
    public double getBoundSnapshotTimestamp() {
        Double t = boundSnapshotTimestamp.get();
        return t != null ? t : Double.NaN;
    }

    /**
     * Debug: @return true, wenn der aktuelle Thread gebunden ist.
     */
    public boolean isBound() {
        return boundTimes.get() != null;
    }

    /**
     * Static view: Free-speed als konstante TravelTime.
     * Wird genutzt, um SpeedyALT-Landmarken einmalig stabil zu berechnen.
     */
    public TravelTime getStaticFreeSpeedView() {
        return (link, time, person, vehicle) -> link.getLength() / link.getFreespeed();
    }

    /**
     * Hot Path: diese Methode wird sehr oft im Router aufgerufen.
     * Deshalb:
     * - kein Map-Lookup pro Call
     * - nur: ThreadLocal lesen (falls gebunden), sonst fallback currentSnapshot.
     */
    @Override
    public double getLinkTravelTime(Link link, double time, Person person, Vehicle vehicle) {
        double[] times = boundTimes.get();
        if (times == null) {
            // Fallback: wenn jemand vergisst zu binden, nehmen wir den aktuellsten Snapshot
            // times = currentSnapshot.get().times;
            throw new IllegalStateException(
                    "TravelTimeSnapshot accessed without thread binding. " +
                            "RoutingService must call bindToTime(...) before routing.");
        }
        return times[linkIdToIndex.get(link.getId())];
    }

    public long getWindowSizeSeconds() {
        return windowSizeSeconds;
    }

    public long getTotalWaitTimeNanos() {
        return totalWaitTimeNanos.get();
    }

    public long getTotalWaitCount() {
        return totalWaitCount.get();
    }
}
