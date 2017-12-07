library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
library work;
use work.rv_components.all;
use work.utils.all;
use work.constants_pkg.all;

entity orca_core is
  generic (
    REGISTER_SIZE          : integer;
    RESET_VECTOR           : std_logic_vector(31 downto 0);
    INTERRUPT_VECTOR       : std_logic_vector(31 downto 0);
    MAX_IFETCHES_IN_FLIGHT : positive range 1 to 4;
    BTB_ENTRIES            : natural;
    MULTIPLY_ENABLE        : natural range 0 to 1;
    DIVIDE_ENABLE          : natural range 0 to 1;
    SHIFTER_MAX_CYCLES     : natural;
    POWER_OPTIMIZED        : natural range 0 to 1;
    COUNTER_LENGTH         : natural;
    ENABLE_EXCEPTIONS      : natural;
    PIPELINE_STAGES        : natural range 4 to 5;
    ENABLE_EXT_INTERRUPTS  : natural range 0 to 1;
    NUM_EXT_INTERRUPTS     : positive range 1 to 32;
    LVE_ENABLE             : natural range 0 to 1;
    SCRATCHPAD_SIZE        : integer;
    WRITE_FIRST_SMALL_RAMS : boolean;
    FAMILY                 : string
    );
  port (
    clk            : in std_logic;
    scratchpad_clk : in std_logic;
    reset          : in std_logic;

    --Instruction Orca-internal memory-mapped master
    ifetch_oimm_address       : buffer std_logic_vector(REGISTER_SIZE-1 downto 0);
    ifetch_oimm_requestvalid  : buffer std_logic;
    ifetch_oimm_readnotwrite  : out    std_logic;
    ifetch_oimm_readdata      : in     std_logic_vector(REGISTER_SIZE-1 downto 0);
    ifetch_oimm_waitrequest   : in     std_logic;
    ifetch_oimm_readdatavalid : in     std_logic;

    --Data Orca-internal memory-mapped master
    lsu_oimm_address       : out    std_logic_vector(REGISTER_SIZE-1 downto 0);
    lsu_oimm_byteenable    : out    std_logic_vector((REGISTER_SIZE/8)-1 downto 0);
    lsu_oimm_requestvalid  : buffer std_logic;
    lsu_oimm_readnotwrite  : buffer std_logic;
    lsu_oimm_writedata     : out    std_logic_vector(REGISTER_SIZE-1 downto 0);
    lsu_oimm_readdata      : in     std_logic_vector(REGISTER_SIZE-1 downto 0);
    lsu_oimm_readdatavalid : in     std_logic;
    lsu_oimm_waitrequest   : in     std_logic;

    --Scratchpad memory-mapped slave
    sp_address   : in  std_logic_vector(log2(SCRATCHPAD_SIZE)-1 downto 0);
    sp_byte_en   : in  std_logic_vector((REGISTER_SIZE/8)-1 downto 0);
    sp_write_en  : in  std_logic;
    sp_read_en   : in  std_logic;
    sp_writedata : in  std_logic_vector(REGISTER_SIZE-1 downto 0);
    sp_readdata  : out std_logic_vector(REGISTER_SIZE-1 downto 0);
    sp_ack       : out std_logic;

    global_interrupts : in std_logic_vector(NUM_EXT_INTERRUPTS-1 downto 0)
    );
end entity orca_core;

architecture rtl of orca_core is
  signal interrupt_pending : std_logic;

  signal flush_pipeline  : std_logic;
  signal ifetch_flushed  : std_logic;
  signal decode_flushed  : std_logic;
  signal execute_flushed : std_logic;
  signal pipeline_empty  : std_logic;

  signal program_counter : unsigned(REGISTER_SIZE-1 downto 0);

  signal execute_to_ifetch_pc_correction_data        : unsigned(REGISTER_SIZE-1 downto 0);
  signal execute_to_ifetch_pc_correction_source_pc   : unsigned(REGISTER_SIZE-1 downto 0);
  signal execute_to_ifetch_pc_correction_valid       : std_logic;
  signal execute_to_ifetch_pc_correction_predictable : std_logic;
  signal ifetch_to_execute_pc_correction_ready       : std_logic;

  signal ifetch_to_decode_instruction     : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
  signal ifetch_to_decode_program_counter : unsigned(REGISTER_SIZE-1 downto 0);
  signal ifetch_to_decode_predicted_pc    : unsigned(REGISTER_SIZE-1 downto 0);
  signal from_ifetch_valid                : std_logic;
  signal decode_to_ifetch_ready           : std_logic;

  signal to_decode_valid                    : std_logic;
  signal decode_to_execute_rs1_data         : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal decode_to_execute_rs2_data         : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal decode_to_execute_rs3_data         : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal decode_to_execute_sign_extension   : std_logic_vector(REGISTER_SIZE-12-1 downto 0);
  signal decode_to_execute_program_counter  : unsigned(REGISTER_SIZE-1 downto 0);
  signal decode_to_execute_predicted_pc     : unsigned(REGISTER_SIZE-1 downto 0);
  signal decode_to_execute_instruction      : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
  signal decode_to_execute_next_instruction : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);
  signal decode_to_execute_next_valid       : std_logic;
  signal from_decode_valid                  : std_logic;
  signal execute_to_decode_ready            : std_logic;

  signal to_execute_valid     : std_logic;
  signal execute_to_rf_select : std_logic_vector(REGISTER_NAME_SIZE-1 downto 0);
  signal execute_to_rf_data   : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal execute_to_rf_valid  : std_logic;
begin
  I : instruction_fetch
    generic map (
      REGISTER_SIZE          => REGISTER_SIZE,
      RESET_VECTOR           => RESET_VECTOR,
      MAX_IFETCHES_IN_FLIGHT => MAX_IFETCHES_IN_FLIGHT,
      BTB_ENTRIES            => BTB_ENTRIES
      )
    port map (
      clk   => clk,
      reset => reset,

      interrupt_pending => interrupt_pending,
      ifetch_flushed    => ifetch_flushed,
      program_counter   => program_counter,

      to_pc_correction_data        => execute_to_ifetch_pc_correction_data,
      to_pc_correction_source_pc   => execute_to_ifetch_pc_correction_source_pc,
      to_pc_correction_valid       => execute_to_ifetch_pc_correction_valid,
      to_pc_correction_predictable => execute_to_ifetch_pc_correction_predictable,
      from_pc_correction_ready     => ifetch_to_execute_pc_correction_ready,

      from_ifetch_instruction     => ifetch_to_decode_instruction,
      from_ifetch_program_counter => ifetch_to_decode_program_counter,
      from_ifetch_predicted_pc    => ifetch_to_decode_predicted_pc,
      from_ifetch_valid           => from_ifetch_valid,
      to_ifetch_ready             => decode_to_ifetch_ready,

      oimm_address       => ifetch_oimm_address,
      oimm_readnotwrite  => ifetch_oimm_readnotwrite,
      oimm_requestvalid  => ifetch_oimm_requestvalid,
      oimm_readdata      => ifetch_oimm_readdata,
      oimm_readdatavalid => ifetch_oimm_readdatavalid,
      oimm_waitrequest   => ifetch_oimm_waitrequest
      );

  to_decode_valid <= from_ifetch_valid and (not flush_pipeline);
  D : decode
    generic map (
      REGISTER_SIZE          => REGISTER_SIZE,
      SIGN_EXTENSION_SIZE    => SIGN_EXTENSION_SIZE,
      LVE_ENABLE             => LVE_ENABLE = 1,
      PIPELINE_STAGES        => PIPELINE_STAGES-3,
      WRITE_FIRST_SMALL_RAMS => WRITE_FIRST_SMALL_RAMS,
      FAMILY                 => FAMILY
      )
    port map (
      clk   => clk,
      reset => reset,

      decode_flushed => decode_flushed,
      flush          => flush_pipeline,

      to_decode_program_counter => ifetch_to_decode_program_counter,
      to_decode_predicted_pc    => ifetch_to_decode_predicted_pc,
      to_decode_instruction     => ifetch_to_decode_instruction,
      to_decode_valid           => to_decode_valid,
      from_decode_ready         => decode_to_ifetch_ready,

      --writeback signals
      to_rf_select => execute_to_rf_select,
      to_rf_data   => execute_to_rf_data,
      to_rf_valid  => execute_to_rf_valid,

      --output signals
      from_decode_rs1_data         => decode_to_execute_rs1_data,
      from_decode_rs2_data         => decode_to_execute_rs2_data,
      from_decode_rs3_data         => decode_to_execute_rs3_data,
      from_decode_sign_extension   => decode_to_execute_sign_extension,
      from_decode_program_counter  => decode_to_execute_program_counter,
      from_decode_predicted_pc     => decode_to_execute_predicted_pc,
      from_decode_instruction      => decode_to_execute_instruction,
      from_decode_next_instruction => decode_to_execute_next_instruction,
      from_decode_next_valid       => decode_to_execute_next_valid,
      from_decode_valid            => from_decode_valid,
      to_decode_ready              => execute_to_decode_ready
      );

  to_execute_valid <= from_decode_valid and (not flush_pipeline);
  X : execute
    generic map (
      REGISTER_SIZE         => REGISTER_SIZE,
      SIGN_EXTENSION_SIZE   => SIGN_EXTENSION_SIZE,
      INTERRUPT_VECTOR      => INTERRUPT_VECTOR,
      BTB_ENTRIES           => BTB_ENTRIES,
      MULTIPLY_ENABLE       => MULTIPLY_ENABLE = 1,
      DIVIDE_ENABLE         => DIVIDE_ENABLE = 1,
      POWER_OPTIMIZED       => POWER_OPTIMIZED = 1,
      SHIFTER_MAX_CYCLES    => SHIFTER_MAX_CYCLES,
      COUNTER_LENGTH        => COUNTER_LENGTH,
      ENABLE_EXCEPTIONS     => ENABLE_EXCEPTIONS = 1,
      ENABLE_EXT_INTERRUPTS => ENABLE_EXT_INTERRUPTS,
      NUM_EXT_INTERRUPTS    => NUM_EXT_INTERRUPTS,
      LVE_ENABLE            => LVE_ENABLE,
      SCRATCHPAD_SIZE       => SCRATCHPAD_SIZE,
      FAMILY                => FAMILY
      )
    port map (
      clk            => clk,
      scratchpad_clk => scratchpad_clk,
      reset          => reset,

      flush_pipeline  => flush_pipeline,
      execute_flushed => execute_flushed,
      pipeline_empty  => pipeline_empty,
      program_counter => program_counter,

      --From previous stage
      to_execute_valid            => to_execute_valid,
      to_execute_program_counter  => decode_to_execute_program_counter,
      to_execute_predicted_pc     => decode_to_execute_predicted_pc,
      to_execute_instruction      => decode_to_execute_instruction,
      to_execute_next_instruction => decode_to_execute_next_instruction,
      to_execute_next_valid       => decode_to_execute_next_valid,
      to_execute_rs1_data         => decode_to_execute_rs1_data,
      to_execute_rs2_data         => decode_to_execute_rs2_data,
      to_execute_rs3_data         => decode_to_execute_rs3_data,
      to_execute_sign_extension   => decode_to_execute_sign_extension,
      from_execute_ready          => execute_to_decode_ready,

      --To PC correction
      to_pc_correction_data        => execute_to_ifetch_pc_correction_data,
      to_pc_correction_source_pc   => execute_to_ifetch_pc_correction_source_pc,
      to_pc_correction_valid       => execute_to_ifetch_pc_correction_valid,
      to_pc_correction_predictable => execute_to_ifetch_pc_correction_predictable,
      from_pc_correction_ready     => ifetch_to_execute_pc_correction_ready,

      --To register file
      to_rf_select => execute_to_rf_select,
      to_rf_data   => execute_to_rf_data,
      to_rf_valid  => execute_to_rf_valid,

      --Data memory-mapped master
      lsu_oimm_address       => lsu_oimm_address,
      lsu_oimm_byteenable    => lsu_oimm_byteenable,
      lsu_oimm_requestvalid  => lsu_oimm_requestvalid,
      lsu_oimm_readnotwrite  => lsu_oimm_readnotwrite,
      lsu_oimm_writedata     => lsu_oimm_writedata,
      lsu_oimm_readdata      => lsu_oimm_readdata,
      lsu_oimm_readdatavalid => lsu_oimm_readdatavalid,
      lsu_oimm_waitrequest   => lsu_oimm_waitrequest,

      --Scratchpad memory-mapped slave
      sp_address   => sp_address,
      sp_byte_en   => sp_byte_en,
      sp_write_en  => sp_write_en,
      sp_read_en   => sp_read_en,
      sp_writedata => sp_writedata,
      sp_readdata  => sp_readdata,
      sp_ack       => sp_ack,

      -- Interrupt lines
      global_interrupts => global_interrupts,
      interrupt_pending => interrupt_pending
      );

  pipeline_empty <= ifetch_flushed and decode_flushed and execute_flushed;
end architecture rtl;
