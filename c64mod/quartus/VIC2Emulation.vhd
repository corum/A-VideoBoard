library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

-- Implement a VIC emulation that sniffs all relevant
-- input/output pins of the VIC and emulates the internal 
-- behaviour of the VIC to finally create a YPbPr signal.
-- Output is generated at every falling edge of the CLK

entity VIC2Emulation is	
	port (
		-- standard definition color output
		COLOR: out std_logic_vector(3 downto 0);
		CSYNC: out std_logic;
		
		-- synchronous clock of 16 times the c64 clock cycle
		CLK         : in std_logic;
		
		-- Connections to the real GTIAs pins 
		PHI0        : in std_logic;
		DB          : in std_logic_vector(11 downto 0);
		A           : in std_logic_vector(5 downto 0);
		RW          : in std_logic; 
		CS          : in std_logic; 
		AEC         : in std_logic;
		
		-- selector to choose PAL(=1) or NTSC(=0) variant
		PAL         : in std_logic
	);	
end entity;


architecture immediate of VIC2Emulation is
	-- video matrix RAM
	signal matrixdata     : std_logic_vector(11 downto 0);
	signal matrixraddress : std_logic_vector (5 downto 0);
	signal matrixwaddress : std_logic_vector (5 downto 0);
	signal matrixq        : std_logic_vector (11 downto 0);

	component ram_dual is
	generic
	(
		data_width : integer := 8;
		addr_width : integer := 16
	); 
	port 
	(
		data	: in std_logic_vector(data_width-1 downto 0);
		raddr	: in std_logic_vector(addr_width-1 downto 0);
		waddr	: in std_logic_vector(addr_width-1 downto 0);
		we		: in std_logic := '1';
		rclk	: in std_logic;
		wclk	: in std_logic;
		q		: out std_logic_vector(data_width-1 downto 0)
	);	
	end component;

	
begin
	videomatrix: ram_dual generic map(data_width => 12, addr_width => 6)
		port map (
			matrixdata,
			matrixraddress,
			matrixwaddress,
			'1',
			CLK,
			CLK,
			matrixq	
		);

	-- main signal processing and video logic
	process (CLK) 
	
	-- registers of the VIC and their default values
  	type T_spritex is array (0 to 7) of std_logic_vector(8 downto 0);
	variable spritex : T_spritex := 
	( "000000000","000000000","000000000","000000000","000000000","000000000","000000000","000000000");	
	variable ECM_SET:          std_logic := '0';
	variable ECM:              std_logic := '0';
	variable BMM_SET:          std_logic := '0';
	variable BMM:              std_logic := '0';
	variable MCM:              std_logic := '0';
	variable DEN:              std_logic := '1';
	variable RSEL:             std_logic := '1';
	variable CSEL:             std_logic := '1';
	variable XSCROLL:          std_logic_vector(2 downto 0) := "000";
	variable spritepriority:   std_logic_vector(7 downto 0) := "00000000";
	variable spritemulticolor: std_logic_vector(7 downto 0) := "00000000";
	variable doublewidth:      std_logic_vector(7 downto 0) := "00000000";
	variable bordercolor:      std_logic_vector(3 downto 0) := "1110"; --
	variable backgroundcolor0: std_logic_vector(3 downto 0) := "0110"; --
	variable backgroundcolor1: std_logic_vector(3 downto 0) := "0001"; --
	variable backgroundcolor2: std_logic_vector(3 downto 0) := "0010"; --
	variable backgroundcolor3: std_logic_vector(3 downto 0) := "0011"; --
	variable spritemulticolor0:std_logic_vector(3 downto 0) := "0100"; --
	variable spritemulticolor1:std_logic_vector(3 downto 0) := "0000";
	type T_spritecolor is array (0 to 7) of std_logic_vector(3 downto 0);
--	variable spritecolor: T_spritecolor := ( "0001", "0010", "0011", "0100", "0101", "0110", "0111", "1100" );
	variable spritecolor: T_spritecolor := ( "0000", "0000", "0000", "0000", "0000", "0000", "0000", "0000" );
	
	-- registering the input lines
	variable in_phi0: std_logic; 
	variable in_db: std_logic_vector(11 downto 0);
	variable in_a:  std_logic_vector(5 downto 0);
	variable in_rw: std_logic; 
	variable in_cs: std_logic; 
	variable in_aec: std_logic; 
	
	-- memory requests to write into registers
	variable register_requestwrite : std_logic := '0';
	variable register_writeaddress : std_logic_vector(5 downto 0);
	variable register_writedata : std_logic_vector(7 downto 0);
	
	-- variables for synchronious operation
	variable displayline: integer range 0 to 511 := 0;  -- VIC-II line numbering
	variable cycle : integer range 0 to 127 := 0;       -- cpu cycle in line (cycle 0: first access to video ram)
	variable phase: integer range 0 to 15 := 0;         -- phase inside of the cycle
	variable xcoordinate : integer range 0 to 511;     -- x-position in sprite coordinates

	variable pixelpattern : std_logic_vector(26 downto 0);
	variable mainborderflipflop : std_logic := '0';
	variable verticalborderflipflop : std_logic := '0';
	variable videomatrixage : integer range 0 to 8 := 8;
	
	variable firstspritereadaddress : std_logic_vector(1 downto 0);	
	variable spritereadcomplete : std_logic;
	variable spritedatabyte0 : std_logic_vector(7 downto 0);
	variable spritedatabyte1 : std_logic_vector(7 downto 0);
	type T_spritedata is array (0 to 7) of std_logic_vector(25 downto 0);
	variable spritedata : T_spritedata;
	type T_spriterendering is array (0 to 7) of std_logic; 
	variable spriterendering : T_spriterendering := ('0','0','0','0','0','0','0','0');

   -- synchronizing the screen by detecing the DRAM refresh pattern	
	variable syncdetect_ok : boolean := false;
	variable syncdetect_cycle : integer range 0 to 127 := 0;
	variable ramrefreshpattern : std_logic_vector(9 downto 0) := "0000000000";
		
	-- registered output 
	variable out_color  : std_logic_vector(3 downto 0) := "0000";
	variable out_csync : std_logic := '0';

	-- temporary stuff
	variable hcounter : integer range 0 to 1023;      -- pixel in current scan line
	variable vcounter : integer range 0 to 1023;      -- current scan line 
	variable tmp_isforeground : boolean;
	variable tmp_ypbpr : std_logic_vector(14 downto 0);
	variable tmp_vm : std_logic_vector(11 downto 0);
	variable tmp_hscroll : integer range 0 to 7;
	variable tmp_bit : std_logic;
	variable tmp_pos : integer range 1 to 27;
	variable tmp_2bit : std_logic_vector(1 downto 0);
	variable tmp_3bit : std_logic_vector(2 downto 0);
	variable tmp_half : integer range 250 to 280;

	begin
		-- synchronous logic -------------------
		if rising_edge(CLK) then	
		
			-- generate pixel output
			if (phase mod 2) = 0 then   
			
				-- output defaults to background (no csync active)
				out_csync := '1';
				out_color := backgroundcolor0;
				tmp_isforeground := false;
				tmp_hscroll := to_integer(unsigned(XSCROLL));
	
				-- main screen area color processing
				 
				-- address the correct video matrix cell for the next clock
				matrixraddress <= std_logic_vector(to_unsigned((xcoordinate - 24 - tmp_hscroll) / 8, 6));
				
				-- get the pixel bits from the shift register
				tmp_vm := "000000000000";
				tmp_bit := '0';
				tmp_2bit := "00";
				if xcoordinate>=25 and xcoordinate<25+320 then
					if videomatrixage<8 and displayline<251 then
						tmp_vm := matrixq;
					end if;
					-- extract relevant bit or 2 bits from bitmap data
					tmp_bit := pixelpattern(18 + tmp_hscroll);
					if (tmp_hscroll mod 2) = 0 then
						tmp_pos := 19 + tmp_hscroll - ((phase/2) mod 2);
					else
						tmp_pos := 18 + tmp_hscroll + ((phase/2) mod 2);
					end if;
					tmp_2bit(1) := pixelpattern(tmp_pos);
					tmp_2bit(0) := pixelpattern(tmp_pos-1);
				end if;
				
				-- set color depending on graphics/text mode
				tmp_3bit(2) := ECM;
				tmp_3bit(1) := BMM;
				tmp_3bit(0) := MCM;
				case tmp_3bit is  
				when "000" =>   -- standard text mode
					if tmp_bit='1' then
						out_color := tmp_vm(11 downto 8);
						tmp_isforeground := true;
					end if;
				when "001" =>   -- multicolor text mode
					if tmp_vm(11)='0' then
						if tmp_bit='1' then
							out_color := "0" & tmp_vm(10 downto 8);
							tmp_isforeground := true;
						end if;
					else
						case tmp_2bit is
						when "00" => out_color := backgroundcolor0;
						when "01" => out_color := backgroundcolor1;
						when "10" => out_color := backgroundcolor2;
										 tmp_isforeground := true;
						when "11" => out_color := "0" & tmp_vm(10 downto 8);
										 tmp_isforeground := true;
						end case;
					end if;
				when "010" =>  -- standard bitmap mode
					if tmp_bit='0' then
						out_color := tmp_vm(3 downto 0);
					else
						out_color := tmp_vm(7 downto 4);
						tmp_isforeground := true;
					end if;
				when "011" =>  -- multicolor bitmap mode
					case tmp_2bit is
					when "00" => out_color := backgroundcolor0;
					when "01" => out_color := tmp_vm(7 downto 4);
					when "10" => out_color := tmp_vm(3 downto 0);
									 tmp_isforeground := true;
					when "11" => out_color := tmp_vm(11 downto 8);
									 tmp_isforeground := true;
					end case;
				when "100" =>  -- ECM text mode
					if tmp_bit='1' then
						out_color := tmp_vm(11 downto 8);
						tmp_isforeground := true;
					else
						case tmp_vm(7 downto 6) is
						when "00" => out_color := backgroundcolor0;
						when "01" => out_color := backgroundcolor1;
						when "10" => out_color := backgroundcolor2;
						when "11" => out_color := backgroundcolor3;
						end case;								
					end if;
				when "101" =>  -- Invalid text mode
					out_color := "0000";
					if tmp_vm(11)='0' then
						if tmp_bit='1' then
							tmp_isforeground := true;
						end if;
					else
						if tmp_2bit="10" or tmp_2bit="11" then	
							tmp_isforeground := true;
						end if;
					end if;							
				when "110" =>  -- Invalid bitmap mode 1
					out_color := "0000";
					if tmp_bit='1' then
						tmp_isforeground := true;
					end if;
				when "111" =>  -- Invalid bitmap mode 2
					out_color := "0000";
					if tmp_2bit="10" or tmp_2bit="11" then
						tmp_isforeground := true;
					end if;
				end case;						
				
				-- overlay with sprite graphics
				for SP in 7 downto 0 loop
					if ((not tmp_isforeground) or spritepriority(SP)='0') and (spriterendering(SP)='1')	then
						if spritemulticolor(SP)='1' then								
							if spritedata(SP)(25) = '0' then
								tmp_2bit := spritedata(SP)(23 downto 22);
							else
								tmp_2bit := spritedata(SP)(24 downto 23);
							end if;
							case tmp_2bit is
							when "00" => 
							when "01" => out_color := spritemulticolor0;
							when "10" => out_color := spritecolor(SP);
							when "11" => out_color := spritemulticolor1;
							end case;
						else
							if spritedata(SP)(23)='1' then
								out_color := spritecolor(SP);						
							end if;
						end if;
					end if;
				end loop;
				
				-- overlay with border 
				if mainborderflipflop='1' then
					out_color := bordercolor;
				end if;
					
				-- override with blankings and sync signals 
				if PAL='1' then
					hcounter := cycle*8 + phase/2;
					vcounter := displayline + 20;
--					if hcounter>=12 then
--						hcounter:=hcounter-12;
--						vcounter := vcounter-1;
--					end if;
					if vcounter>=312 then
						vcounter := vcounter-312;
					end if;
					tmp_half := 252;
				else
					hcounter := cycle*8 + phase/2; 
					vcounter := displayline+253;
--					if hcounter>=12 then
--						hcounter := hcounter-12;
--					else
--						hcounter := hcounter+(520-12);
--						vcounter := vcounter-1;
--					end if;					
					if vcounter>=263 then
						vcounter := vcounter-263;
					end if;
					tmp_half := 260;
				end if;
				if hcounter<288-205 or hcounter>=288+205 
				or (PAL='0' and (vcounter<141-120 or vcounter>=141+120))
				or (PAL='1' and (vcounter<166-144 or vcounter>=166+144))
				then
					out_color := "0000";
	
					-- generate csync for PAL or NTSC
					if (vcounter=0) and (hcounter<37 or (hcounter>=tmp_half and hcounter<tmp_half+18)) then                       -- normal sync, short sync
						out_csync := '0';
					elsif (vcounter=1 or vcounter=2) and (hcounter<18 or (hcounter>=tmp_half and hcounter<tmp_half+18)) then      -- 2x 2 short syncs
						out_csync := '0';
					elsif (vcounter=3 or vcounter=4) and (hcounter<tmp_half-18 or (hcounter>=tmp_half and hcounter<2*tmp_half-18)) then  -- 2x 2 vsyncs
						out_csync := '0';
					elsif (vcounter=5) and (hcounter<tmp_half-18 or (hcounter>=tmp_half and hcounter<tmp_half+18)) then           -- one vsync, one short sync
						out_csync := '0';
					elsif (vcounter=6 or vcounter=7) and (hcounter<18 or (hcounter>=tmp_half and hcounter<tmp_half+18)) then      -- 2x 2 short syncs
						out_csync := '0';
					elsif (vcounter>=8) and (hcounter<37) then                                                                    -- normal syncs
						out_csync := '0';
					end if;		
				end if;
				
			
				-- shift pixels along through buffers
				pixelpattern := pixelpattern(25 downto 0) & '0';
				
				-- check the vertical line hit conditions			
				if (RSEL='0' and displayline=55) or (RSEL='1' and displayline=51) then
					if DEN='1' then verticalborderflipflop:='0'; end if;
				elsif (RSEL='0' and displayline=247) or (RSEL='1' and displayline=251) then
					verticalborderflipflop:='1'; 
				end if;
				-- check the horizonal conditions 
				if (CSEL='0' and xcoordinate=31) or (CSEL='1' and xcoordinate=24) then
					if verticalborderflipflop='0' then mainborderflipflop:='0'; end if;
				elsif (CSEL='0' and xcoordinate=335) or (CSEL='1' and xcoordinate=344) then 
					mainborderflipflop:='1';
				end if;
				
				-- progress sprite rendering on every pixel 
				for SP in 0 to 7 loop
					if spriterendering(SP)='1' then
						if doublewidth(SP)='0' 
						or (xcoordinate mod 2) = (to_integer(unsigned(spritex(SP))) mod 2)  then 
							spritedata(SP) := (not spritedata(SP)(25)) & spritedata(SP)(23 downto 0) & '0';
						end if;
					elsif xcoordinate=to_integer(unsigned(spritex(SP))) then
						spriterendering(SP) := '1';
					end if;
				end loop;
				
				-- horizontal pixel coordinate runs independent of the CPU cycle, but is synced to it
				if cycle=11 and phase=4 then
					xcoordinate := 493;
				else
					xcoordinate := xcoordinate+1;
				end if;
			end if;
			
			-- data from memory
			if phase=7 then                -- received in first half of cycle
				-- pixel pattern read
				if cycle>=15 and cycle<55 then
					pixelpattern(7 downto 0) := in_db(7 downto 0);
				end if;
				-- sprite DMA read
				if cycle=59 or cycle=61 or cycle=63 or cycle=0 or cycle=2 or cycle=4 or cycle=6 or cycle=8 then
					spritedatabyte1 := in_db(7 downto 0);
				end if;
			end if;
			if phase=14 and in_aec='0' then   -- receive during a CPU-blocking second half of a cycle
				-- video matrix read
				if cycle>=14 and cycle<54 then
					matrixdata <= in_db;
					matrixwaddress <= std_logic_vector(to_unsigned(cycle-14,6));
					videomatrixage := 0;
				end if;
				-- sprite DMA read
				if cycle=58 or cycle=60 or cycle=62 or cycle=64 or cycle=1 or cycle=3 or cycle=5 or cycle=7 then
					spritedatabyte0 := in_db(7 downto 0);
				end if;
				-- read the last byte for a sprite
				for SP in 0 to 7 loop
					if (SP=0 and cycle=59) or (SP=1 and cycle=61) or (SP=2 and cycle=63) or (SP=3 and cycle=0)
					or (SP=4 and cycle=2) or (SP=5 and cycle=4) or (SP=6 and cycle=6) or (SP=7 and cycle=8) then
						spriterendering(SP) := '0';
						if spritereadcomplete='1' then
							spritedata(SP) := "00" & spritedatabyte0 & spritedatabyte1 & in_db(7 downto 0);
						else
							spritedata(SP) := "00000000000000000000000000";
						end if;
					end if;
				end loop;
			end if;
			
			-- detect if there was a real sprite read (when the
			-- read address did change between individual bytes)
			-- (very short time slot were address is stable)
			if phase=9 then
				if cycle=58 or cycle=60 or cycle=62 or cycle=64 or cycle=1 or cycle=3 or cycle=5 or cycle=7 then
					firstspritereadaddress := in_a(1 downto 0);
				elsif cycle=59 or cycle=61 or cycle=63 or cycle=0 or cycle=2 or cycle=4 or cycle=6 or cycle=8 then
					if in_aec='0' and firstspritereadaddress /= in_a(1 downto 0) then
						spritereadcomplete := '1';
					else
						spritereadcomplete := '0';
					end if;
				end if;
			end if;
			
			-- make the changes to some registers have delayed effect
			if phase=9 then
				ECM := ECM_SET;
				BMM := BMM_SET;
			end if;

			-- detect if a register write should happen in this cycle
			if phase=9 then
				register_writeaddress := in_a;
			end if;
			if phase=12 and in_aec='1' and in_cs='0' and in_rw='0' then
				register_writedata := in_db(7 downto 0);
				register_requestwrite := '1';
			end if;
			-- write the new value through to the registers before next cycle
			if phase=15 and register_requestwrite = '1' then
				register_requestwrite := '0';
				case to_integer(unsigned(register_writeaddress)) is 
					when 0  => spritex(0)(7 downto 0) := register_writedata;
					when 2  => spritex(1)(7 downto 0) := register_writedata;
					when 4  => spritex(2)(7 downto 0) := register_writedata;
					when 6  => spritex(3)(7 downto 0) := register_writedata;
					when 8  => spritex(4)(7 downto 0) := register_writedata;
					when 10 => spritex(5)(7 downto 0) := register_writedata;
					when 12 => spritex(6)(7 downto 0) := register_writedata;
					when 14 => spritex(7)(7 downto 0) := register_writedata;
					when 16 => spritex(0)(8) := register_writedata(0);
					           spritex(1)(8) := register_writedata(1);
								  spritex(2)(8) := register_writedata(2);
								  spritex(3)(8) := register_writedata(3);
								  spritex(4)(8) := register_writedata(4);
								  spritex(5)(8) := register_writedata(5);
								  spritex(6)(8) := register_writedata(6);
								  spritex(7)(8) := register_writedata(7);
					when 17 => ECM_SET := register_writedata(6);
	                       BMM_SET := register_writedata(5);
								  DEN := register_writedata(4);
								  RSEL:= register_writedata(3);
					when 22 => MCM := register_writedata(4);
					           CSEL := register_writedata(3);
								  XSCROLL := register_writedata(2 downto 0);
					when 27 => spritepriority := register_writedata;
					when 28 => spritemulticolor := register_writedata;
					when 29 => doublewidth := register_writedata;
					when 32 => bordercolor := register_writedata(3 downto 0);
					when 33 => backgroundcolor0 := register_writedata(3 downto 0);
					when 34 => backgroundcolor1 := register_writedata(3 downto 0);
					when 35 => backgroundcolor2 := register_writedata(3 downto 0);
					when 36 => backgroundcolor3 := register_writedata(3 downto 0);
					when 37 => spritemulticolor0 := register_writedata(3 downto 0);
					when 38 => spritemulticolor1 := register_writedata(3 downto 0);
					when 39 => spritecolor(0) := register_writedata(3 downto 0);
					when 40 => spritecolor(1) := register_writedata(3 downto 0);
					when 41 => spritecolor(2) := register_writedata(3 downto 0);
					when 42 => spritecolor(3) := register_writedata(3 downto 0);
					when 43 => spritecolor(4) := register_writedata(3 downto 0);
					when 44 => spritecolor(5) := register_writedata(3 downto 0);
					when 45 => spritecolor(6) := register_writedata(3 downto 0);
					when 46 => spritecolor(7) := register_writedata(3 downto 0);
					when others => null;
				end case;
			end if;

			-- progress horizontal and vertical counters
			if phase=15 then
				if cycle=64 then
					cycle := 0;
					if (displayline=262 and PAL='0') or displayline=311 then
						displayline := 0;
					else
						displayline := displayline+1;
					end if;
					if videomatrixage<8 then 
						videomatrixage := videomatrixage+1;
					end if;
				else
					if PAL='1' and cycle=57 then   -- for PAL skip two of the cycles
						cycle := 59;
					elsif PAL='1' and cycle=9 then
						cycle := 11;
					else
						cycle := cycle+1;
					end if;
				end if;
			end if;

			-- try to find the dram refresh pattern to sync the output 
			if phase=1 then
				case syncdetect_cycle is
				when 0 => ramrefreshpattern(9 downto 8) := in_a(1 downto 0);
				when 1 => ramrefreshpattern(7 downto 6) := in_a(1 downto 0);
				when 2 => ramrefreshpattern(5 downto 4) := in_a(1 downto 0);
				when 3 => ramrefreshpattern(3 downto 2) := in_a(1 downto 0);
				when 4 => ramrefreshpattern(1 downto 0) := in_a(1 downto 0);
				when 5 => 
					if ramrefreshpattern = "1110010011" 
					or ramrefreshpattern = "1001001110"
					or ramrefreshpattern = "0100111001"
					or ramrefreshpattern = "0011100100"
					then
						syncdetect_ok := true;  -- have detected the refresh pattern
					elsif syncdetect_ok then
						syncdetect_ok := false; -- not detected for 1. time 
						-- detect the bottom of the frame anomaly (when in sync)
						if ramrefreshpattern = "1111111111" then
							cycle := 15;	
							if PAL='1' then
								displayline := 311;
							else
								displayline := 262;
							end if;
						end if;
					else 
						syncdetect_cycle := 6;  -- two missdetecions: search for sync
					end if;
				when others =>
				end case;
				if (syncdetect_cycle=62 and PAL='1') or syncdetect_cycle=64 then 
					syncdetect_cycle := 0;
				else
					syncdetect_cycle := syncdetect_cycle+1;
				end if;
			end if;
			
			-- progress the phase
			if phase>12 and in_phi0='0' then
				phase:=0;
			elsif phase<15 then
				phase:=phase+1;
			end if;

			-- take signals into registers
			in_phi0 := PHI0;
			in_db := DB;
			in_a := A;
			in_rw := RW; 
			in_cs := CS; 
			in_aec := AEC;			
		-- end of synchronous logic
		end if;		
		
		-------------------- output signals ---------------------		
		COLOR <= out_color;
		CSYNC <= out_csync;
	end process;
	
end immediate;

