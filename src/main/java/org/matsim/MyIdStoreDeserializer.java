package org.matsim;

import com.google.protobuf.CodedInputStream;
import net.jpountz.lz4.LZ4FrameInputStream;

import java.io.*;
import java.nio.file.Path;
import java.util.*;

public class MyIdStoreDeserializer {
    // Exakt abgeglichen mit deiner Rust StableTypeId-Implementierung
    public static final long STRING_TYPE_ID = 1L;
    public static final long PERSON_TYPE_ID = 2L;
    public static final long LINK_TYPE_ID = 3L;
    public static final long NODE_TYPE_ID = 4L;
    public static final long VEHICLE_TYPE_ID = 6L;

    public static Map<Long, List<String>> loadIdStore(Path path) {
        Map<Long, List<String>> idStore = new HashMap<>();

        try (InputStream fis = new FileInputStream(path.toFile())) {
            CodedInputStream cis = CodedInputStream.newInstance(fis);

            while (!cis.isAtEnd()) {
                // Liest das Längenpräfix der IdsWithType-Nachricht
                int messageLength = cis.readRawVarint32();
                int oldLimit = cis.pushLimit(messageLength);

                long typeId = 0;
                byte[] dataBytes = null;
                boolean isLz4 = false;

                // Feldweises Auslesen der Protobuf-Nachricht (ohne generierte Klassen)
                while (!cis.isAtEnd()) {
                    int tag = cis.readTag();
                    int fieldNumber = tag >>> 3;
                    if (fieldNumber == 1) { // type_id
                        typeId = cis.readUInt64();
                    } else if (fieldNumber == 2) { // Data::Raw
                        dataBytes = cis.readBytes().toByteArray();
                        isLz4 = false;
                    } else if (fieldNumber == 3) { // Data::Lz4Data
                        dataBytes = cis.readBytes().toByteArray();
                        isLz4 = true;
                    } else {
                        cis.skipField(tag);
                    }
                }
                cis.popLimit(oldLimit);

                if (dataBytes != null) {
                    if (isLz4) dataBytes = decompressLz4(dataBytes);
                    idStore.put(typeId, decodeStrings(dataBytes));
                }
            }
        } catch (IOException e) {
            throw new RuntimeException("Fehler beim Laden des IdStores: " + path, e);
        }
        return idStore;
    }

    private static byte[] decompressLz4(byte[] compressed) throws IOException {
        try (InputStream in = new LZ4FrameInputStream(new ByteArrayInputStream(compressed));
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            in.transferTo(out);
            return out.toByteArray();
        }
    }

    private static List<String> decodeStrings(byte[] bytes) throws IOException {
        List<String> strings = new ArrayList<>();
        CodedInputStream cis = CodedInputStream.newInstance(bytes);
        while (!cis.isAtEnd()) {
            strings.add(cis.readString());
        }
        return strings;
    }
}