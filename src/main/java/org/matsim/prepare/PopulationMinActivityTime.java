package org.matsim.prepare;

import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.population.Activity;
import org.matsim.api.core.v01.population.Person;
import org.matsim.api.core.v01.population.Population;
import org.matsim.application.MATSimAppCommand;
import org.matsim.core.population.PopulationUtils;
import org.matsim.core.router.TripStructureUtils;
import picocli.CommandLine;

import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class PopulationMinActivityTime implements MATSimAppCommand {
    @CommandLine.Option(names = "--input", description = "Path to population", required = true)
    private Path input;

    @CommandLine.Option(names = "--output", description = "Path to population", required = true)
    private Path output;

    @CommandLine.Option(names = "--min-duration", description = "Path to population")
    private int minDuration = 300;

    public static void main(String[] args) {
        new PopulationMinActivityTime().execute(new String[]{
                "--input", "/Users/paulh/public-svn/matsim/scenarios/countries/de/berlin/berlin-v6.4/input/berlin-v6.4-1pct.plans.xml.gz", "--output", "output"
        });
    }

    @Override
    public Integer call() throws Exception {
        String experiencedPlans = getExperiencedPlansUrl();
        Population inputPop = PopulationUtils.readPopulation(input.toString());
        Population experiencedPop = PopulationUtils.readPopulation(experiencedPlans);

        Set<Id<Person>> toDelete = new HashSet<>();

        for (Person person : inputPop.getPersons().values()) {
            Id<Person> inputId = person.getId();
            Person experiencedReference = experiencedPop.getPersons().get(inputId);
            List<Activity> referenceActivities = TripStructureUtils.getActivities(experiencedReference.getSelectedPlan(), TripStructureUtils.StageActivityHandling.ExcludeStageActivities);
            List<Activity> activities = TripStructureUtils.getActivities(person.getSelectedPlan(), TripStructureUtils.StageActivityHandling.ExcludeStageActivities);

            // experienced plans won't contain the agent if there is no leg.
            if (activities.size() == 1 && referenceActivities.isEmpty()) {
                continue;
            }

            // exclude stuck persons
            if(referenceActivities.size()!= activities.size()) {
//                throw new RuntimeException("Number of acts differ for agent " + inputId + ". Ref "+ referenceActivities.size() + " vs. input " + activities.size());
                System.out.println("Number of acts differ for agent " + inputId + ". Ref "+ referenceActivities.size() + " vs. input " + activities.size() + "... Skipping...");
                toDelete.add(inputId);
                continue;
            }

            // skip home activity and last activity
            for (int i = 1; i < activities.size()-1; i++) {
                double referenceStart = referenceActivities.get(i).getStartTime().orElseThrow(RuntimeException::new);
                double referenceEnd = referenceActivities.get(i).getEndTime().orElseThrow(RuntimeException::new);
                double newDuration = referenceEnd - referenceStart;
                activities.get(i).setMaximumDuration(Math.max(newDuration, minDuration));
                activities.get(i).setStartTimeUndefined();
                activities.get(i).setEndTimeUndefined();
            }
        }

        System.out.println("Removing " + toDelete.size() + " agents with stuck activities.");
        inputPop.getPersons().values().removeIf(p -> toDelete.contains(p.getId()));
        PopulationUtils.writePopulation(inputPop, output.resolve("min-act-pop.xml.gz").toString());

        return 0;
    }

    private String getExperiencedPlansUrl() {
        String experiencedPlans;
        if (input.getFileName().toString().contains("1pct")) {
            experiencedPlans = "https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-v6.4/output/berlin-v6.4-1pct/013.output_experienced_plans.xml.gz";
        } else if (input.getFileName().toString().contains("10pct")) {
            experiencedPlans = "https://svn.vsp.tu-berlin.de/repos/public-svn/matsim/scenarios/countries/de/berlin/berlin-v6.4/output/berlin-v6.4-10pct/berlin-v6.4.output_experienced_plans.xml.gz";
        } else {
            throw new RuntimeException("need to start with 1 or 10 pct plans.");
        }
        return experiencedPlans;
    }
}
