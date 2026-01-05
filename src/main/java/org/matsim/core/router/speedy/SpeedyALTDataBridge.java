package org.matsim.core.router.speedy;

import org.matsim.core.router.util.LeastCostPathCalculator;
import org.matsim.core.router.util.TravelDisutility;
import org.matsim.core.router.util.TravelTime;

public class SpeedyALTDataBridge {

    /**
     * Da diese Methode im selben Package wie SpeedyALTData deklariert ist,
     * hat sie Zugriff auf den package-private Konstruktor.
     */
    public static Object createSharedData(SpeedyGraph graph, int landmarksCount, TravelDisutility staticCosts) {
        return new SpeedyALTData(graph, landmarksCount, staticCosts);
    }

    /**
     * Erstellt den eigentlichen Router.
     * Da wir SpeedyALTData außerhalb des Packages nur als 'Object' führen können,
     * casten wir es hier intern zurück.
     */
    public static LeastCostPathCalculator createRouter(Object sharedData, TravelTime tt, TravelDisutility td) {
        return new SpeedyALT((SpeedyALTData) sharedData, tt, td);
    }
}