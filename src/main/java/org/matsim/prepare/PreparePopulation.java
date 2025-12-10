package org.matsim.prepare;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.matsim.api.core.v01.Id;
import org.matsim.api.core.v01.population.*;
import org.matsim.application.MATSimAppCommand;
import org.matsim.application.prepare.population.CleanPopulation;
import org.matsim.core.population.PopulationUtils;
import org.matsim.core.router.TripStructureUtils;
import picocli.CommandLine;

import java.nio.file.Path;
import java.util.List;
import java.util.Set;

@CommandLine.Command(
        name = "prepare-population",
        description = "Filters population by a given set of modes. Preserves all agents using only these modes. Attach preplanning horizon to pt legs.")
public class PreparePopulation implements MATSimAppCommand {
    public static final Logger log = LogManager.getLogger(PreparePopulation.class);

    @CommandLine.Option(names = "--input", description = "Path to population", required = true)
    private Path input;

    @CommandLine.Option(names = "--modes", split = ",", description = "Positive set of modes that the population is allowed to use")
    private Set<String> modes;

    @CommandLine.Option(names = "--horizon", description = "Preplanning horizon to attach to pt legs (in seconds)", defaultValue = "600")
    private int horizon;

    @Override
    public Integer call() {
        Population inputPopulation = PopulationUtils.readPopulation(input.toString());
        log.info("Read population with {} agents", inputPopulation.getPersons().size());
        log.info("Filtering population with the following modes: {}", modes);

        List<Id<Person>> filteredPersons = inputPopulation.getPersons().values().stream()
                .map(HasPlansAndId::getSelectedPlan)
                .filter(p -> TripStructureUtils.getLegs(p).stream().anyMatch(l -> !modes.contains(l.getMode())) || !allActivityLinksSet(p))
                .map(p -> p.getPerson().getId()).toList();

        log.info("Removing {} agents from population", filteredPersons.size());

        for (Id<Person> id : filteredPersons) {
            inputPopulation.removePerson(id);
        }

        for (Person person : inputPopulation.getPersons().values()) {
            CleanPopulation.removeUnselectedPlans(person);
            TripStructureUtils.getTrips(person.getSelectedPlan()).stream()
                    .filter(t -> TripStructureUtils.identifyMainMode(t.getTripElements()).equals("car"))
                    .forEach(t -> t.getLegsOnly().getFirst().getAttributes().putAttribute("preplanningHorizon", 10 * 60));
        }

        log.info("Filtered population contains {} agents", inputPopulation.getPersons().size());

        String output = input.toString().replace(".xml", "-filtered_" + horizon + ".xml");
        log.info("Writing filtered population to {}", output);

        PopulationUtils.writePopulation(inputPopulation, output);

        return 0;
    }

    private static boolean allActivityLinksSet(Plan plan) {
        for (Activity act : TripStructureUtils.getActivities(plan, TripStructureUtils.StageActivityHandling.StagesAsNormalActivities)) {
            if (act.getLinkId() == null) {
                log.warn("Person {} has activities with no link id.", plan.getPerson().getId());
                return false;
            }
        }
        return true;
    }
}
