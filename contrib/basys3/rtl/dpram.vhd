-- Portable dual-port RAM, entity- and port-compatible replacement for the
-- pristine Altera-only dpram.vhd (altsyncram). Same interface contract:
--   * two write ports (wren_a/wren_b), two registered read-forwarding outputs
--   * data_width_g/add_addr_width_g generics match the pristine entity
--
-- Xilinx (Artix-7) implementation. Vivado 2020.2 infers distributed RAM for
-- the small widths used here (dkongjr_rom cores) from this behavioral form.
--
-- Read-during-write: write-first on collision -- the port that writes the
-- same address drives its own output with the new data (mirrors
-- altsyncram's NEW_DATA_NO_NBE_READ for the common single-writer usage
-- here).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram is
	generic (
		addr_width_g : integer := 8;
		data_width_g : integer := 8
	);
	port (
		address_a : in  std_logic_vector (addr_width_g-1 downto 0);
		address_b : in  std_logic_vector (addr_width_g-1 downto 0);
		clock_a   : in  std_logic := '1';
		clock_b   : in  std_logic;
		data_a    : in  std_logic_vector (data_width_g-1 downto 0);
		data_b    : in  std_logic_vector (data_width_g-1 downto 0) := (others => '0');
		enable_a  : in  std_logic := '1';
		enable_b  : in  std_logic := '1';
		wren_a    : in  std_logic := '0';
		wren_b    : in  std_logic := '0';
		q_a       : out std_logic_vector (data_width_g-1 downto 0);
		q_b       : out std_logic_vector (data_width_g-1 downto 0)
	);
end dpram;

architecture rtl of dpram is

	type ram_t is array (0 to (2**addr_width_g)-1) of std_logic_vector (data_width_g-1 downto 0);
	shared variable ram : ram_t := (others => (others => '0'));

begin

	-- Port A: registered read, write-first on collision (matches the
	-- pristine altsyncram's CLOCK1-registered-output convention closely
	-- enough for this core's usage -- see PORTING_SPEC.md section 12 item 4
	-- for the unresolved timing-match caveat).
	process (clock_a)
	begin
		if rising_edge(clock_a) then
			if enable_a = '1' then
				if wren_a = '1' then
					ram(to_integer(unsigned(address_a))) := data_a;
					q_a <= data_a;
				else
					q_a <= ram(to_integer(unsigned(address_a)));
				end if;
			end if;
		end if;
	end process;

	-- Port B: same convention, independent clock.
	process (clock_b)
	begin
		if rising_edge(clock_b) then
			if enable_b = '1' then
				if wren_b = '1' then
					ram(to_integer(unsigned(address_b))) := data_b;
					q_b <= data_b;
				else
					q_b <= ram(to_integer(unsigned(address_b)));
				end if;
			end if;
		end if;
	end process;

end rtl;