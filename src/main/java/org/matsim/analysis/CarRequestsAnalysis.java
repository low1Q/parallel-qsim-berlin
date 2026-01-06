package org.matsim.analysis;

import org.matsim.api.core.v01.population.HasPlansAndId;
import org.matsim.api.core.v01.population.Population;
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.population.PopulationUtils;
import org.matsim.core.router.TripStructureUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import picocli.CommandLine;

import java.util.List;

public class CarRequestsAnalysis implements MATSimAppCommand {
    Logger log = LoggerFactory.getLogger(CarRequestsAnalysis.class);

    @CommandLine.Option(names = "--population", description = "Path to config", defaultValue = "output/v6.4/1pct/berlin-v6.4.output_experienced_plans.xml.gz")
    String populationPath;

    public static void main(String[] args) {
        new CarRequestsAnalysis().execute(args);
    }

    @Override
    public Integer call() throws Exception {
        Population population = PopulationUtils.readPopulation(populationPath);

        List<Double> endTimes = population.getPersons().values().stream()
                .map(HasPlansAndId::getSelectedPlan)
                .flatMap(p -> TripStructureUtils.getTrips(p).stream())
                .filter(t -> TripStructureUtils.identifyMainMode(t.getLegsOnly()).equals("car"))
                .map(t -> t.getOriginActivity().getEndTime().orElseThrow(RuntimeException::new))
                .toList();

        //write end times to file
        String outputFile = "output/times.txt";
        try (java.io.BufferedWriter writer = java.nio.file.Files.newBufferedWriter(java.nio.file.Paths.get(outputFile))) {
            writer.write("end_time");
            writer.newLine();
            for (Double endTime : endTimes) {
                writer.write(String.valueOf(endTime));
                writer.newLine();
            }
        }

        return 0;
    }
}
