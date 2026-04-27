package org.matsim.prepare;

import org.matsim.application.MATSimApplication;
import picocli.CommandLine;

@CommandLine.Command(header = ":: ParallelQSimBerlinPreparation ::", version = "1.0", mixinStandardHelpOptions = true)
@MATSimApplication.Prepare({PreparePopulation.class, AdaptVehicleTypes.class})
public class RunParallelQSimBerlinPreparation extends MATSimApplication {
    static void main(String[] args) {
        MATSimApplication.run(RunParallelQSimBerlinPreparation.class, args);
    }
} //, PrepareNetwork.class
