package org.matsim.prepare;

import org.matsim.api.core.v01.Id;
import org.matsim.application.MATSimAppCommand;
import org.matsim.vehicles.*;
import picocli.CommandLine;

import java.nio.file.Path;

@CommandLine.Command(
        name = "adapt-vehicle-types",
        description = "Adds a walk vehicle type to the vehicle types file."
)
public class AdaptVehicleTypes implements MATSimAppCommand {
    @CommandLine.Option(names = "--input", description = "Path to the input vehicle types file", required = true)
    private Path input;

    @Override
    public Integer call() throws Exception {
        Vehicles vehiclesContainer = VehicleUtils.createVehiclesContainer();
        MatsimVehicleReader vehicleReader = new MatsimVehicleReader(vehiclesContainer);
        vehicleReader.readFile(input.toString());

        VehicleType vehType = VehicleUtils.createVehicleType(Id.create("walk", VehicleType.class));
        vehType.setMaximumVelocity(1.23)
                .setPcuEquivalents(0.1)
                .setNetworkMode("walk")
                .setFlowEfficiencyFactor(10.0);
        vehiclesContainer.addVehicleType(vehType);

        MatsimVehicleWriter vehicleWriter = new MatsimVehicleWriter(vehiclesContainer);
        String output = input.toString().replace(".xml", "-including-walk.xml");
        vehicleWriter.writeFile(output);

        return 0;
    }
}
