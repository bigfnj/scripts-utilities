// Functional headless fixture, not game reconstruction code.
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.IntegerDataType;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;

public class LegacyDosSmoke extends GhidraScript {
    @Override
    public void run() throws Exception {
        Address start = currentProgram.getMinAddress();
        disassemble(start);
        Function function = getFunctionAt(start);
        if (function == null) {
            function = createFunction(start, "toolbox_return_seven");
        }
        if (function == null) {
            throw new IllegalStateException("Fixture function was not created");
        }
        function.setReturnType(IntegerDataType.dataType, SourceType.USER_DEFINED);
        DecompInterface decompiler = new DecompInterface();
        try {
            if (!decompiler.openProgram(currentProgram)) {
                throw new IllegalStateException("Decompiler did not open fixture");
            }
            DecompileResults result = decompiler.decompileFunction(function, 30, monitor);
            if (!result.decompileCompleted() || result.getDecompiledFunction() == null) {
                throw new IllegalStateException("Fixture did not decompile");
            }
            String code = result.getDecompiledFunction().getC();
            if (!code.matches("(?s).*return\\s+(?:0x)?7\\s*;.*")) {
                throw new IllegalStateException("Expected return 7, got: " + code);
            }
            println("TOOLBOX_GHIDRA_SMOKE_OK");
        } finally {
            decompiler.dispose();
        }
    }
}
