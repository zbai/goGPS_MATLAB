function goGPS_LS_SA_code_phase(time_rx, pr1, pr2, ph1, ph2, snr, Eph, SP3_time, SP3_coor, SP3_clck, iono, phase)

% SYNTAX:
%   goGPS_LS_SA_code_phase(time_rx, pr1, pr2, ph1, ph2, snr, Eph, SP3_time, SP3_coor, SP3_clck, iono, phase);
%
% INPUT:
%   time_rx  = GPS reception time
%   pr1      = code observations (L1 carrier)
%   pr2      = code observations (L2 carrier)
%   ph1      = phase observations (L1 carrier)
%   ph2      = phase observations (L2 carrier)
%   snr      = signal-to-noise ratio
%   Eph      = satellite ephemeris
%   SP3_time = precise ephemeris time
%   SP3_coor = precise ephemeris coordinates
%   SP3_clck = precise ephemeris clocks
%   iono     = ionosphere parameters
%   phase    = L1 carrier (phase=1), L2 carrier (phase=2)
%
% DESCRIPTION:
%   Computation of the receiver position (X,Y,Z).
%   Standalone code and phase positioning by least squares adjustment.

%----------------------------------------------------------------------------------------------
%                           goGPS v0.3.1 beta
%
% Copyright (C) 2009-2012 Mirko Reguzzoni, Eugenio Realini
%----------------------------------------------------------------------------------------------
%
%    This program is free software: you can redistribute it and/or modify
%    it under the terms of the GNU General Public License as published by
%    the Free Software Foundation, either version 3 of the License, or
%    (at your option) any later version.
%
%    This program is distributed in the hope that it will be useful,
%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%    GNU General Public License for more details.
%
%    You should have received a copy of the GNU General Public License
%    along with this program.  If not, see <http://www.gnu.org/licenses/>.
%----------------------------------------------------------------------------------------------

global sigmaq0 sigmaq0_N
global cutoff snr_threshold cond_num_threshold o1 o2 o3

global Xhat_t_t Cee conf_sat conf_cs pivot pivot_old
global azR elR distR
global PDOP HDOP VDOP

%covariance matrix initialization
cov_XR = [];

%topocentric coordinate initialization
azR   = zeros(32,1);
elR   = zeros(32,1);
distR = zeros(32,1);

%--------------------------------------------------------------------------------------------
% SELECTION SINGLE / DOUBLE FREQUENCY
%--------------------------------------------------------------------------------------------

%number of unknown phase ambiguities
if (length(phase) == 1)
    nN = 32;
else
    nN = 64;
end

%--------------------------------------------------------------------------------------------
% SATELLITE SELECTION
%--------------------------------------------------------------------------------------------

if (length(phase) == 2)
    sat_pr = find( (pr1 ~= 0) & (pr2 ~= 0) );
    sat = find( (pr1 ~= 0) & (ph1 ~= 0) & ...
        (pr2 ~= 0) & (ph2 ~= 0) );
else
    if (phase == 1)
        sat_pr = find( (pr1 ~= 0) );
        sat = find( (pr1 ~= 0) & (ph1 ~= 0) );
    else
        sat_pr = find( (pr2 ~= 0) );
        sat = find( (pr2 ~= 0) & (ph2 ~= 0) );
    end
end

%zero vector useful in matrix definitions
Z_om_1 = zeros(o1-1,1);
sigma2_N = zeros(nN,1);

if (size(sat,1) >= 4)
    
    sat_pr_old = sat_pr;
    
    if (phase == 1)
        [XR, dtR, XS, dtS, XS_tx, VS_tx, time_tx, err_tropo, err_iono, sat_pr, elR(sat_pr), azR(sat_pr), distR(sat_pr), cov_XR, var_dtR, PDOP, HDOP, VDOP, cond_num] = init_positioning(time_rx, pr1(sat_pr), snr(sat_pr), Eph, SP3_time, SP3_coor, SP3_clck, iono, [], [], [], sat_pr, cutoff, snr_threshold, 0, 0); %#ok<ASGLU>
    else
        [XR, dtR, XS, dtS, XS_tx, VS_tx, time_tx, err_tropo, err_iono, sat_pr, elR(sat_pr), azR(sat_pr), distR(sat_pr), cov_XR, var_dtR, PDOP, HDOP, VDOP, cond_num] = init_positioning(time_rx, pr2(sat_pr), snr(sat_pr), Eph, SP3_time, SP3_coor, SP3_clck, iono, [], [], [], sat_pr, cutoff, snr_threshold, 0, 0); %#ok<ASGLU>
    end
    
    %apply cutoffs also to phase satellites
    sat_removed = setdiff(sat_pr_old, sat_pr);
    sat(ismember(sat,sat_removed)) = [];
    
    %--------------------------------------------------------------------------------------------
    % SATELLITE CONFIGURATION SAVING
    %--------------------------------------------------------------------------------------------
    
    %satellite configuration
    conf_sat = zeros(32,1);
    conf_sat(sat_pr,1) = -1;
    conf_sat(sat,1) = +1;
    
    %no cycle-slips when working with code only
    conf_cs = zeros(32,1);
    
    %previous pivot
    pivot_old = 0;
    
    %actual pivot
    [null_max_elR, i] = max(elR(sat)); %#ok<ASGLU>
    pivot = sat(i);
    
    %if less than 4 satellites are available after the cutoffs, or if the 
    % condition number in the least squares exceeds the threshold
    if (size(sat,1) < 4 | cond_num > cond_num_threshold)

        if (~isempty(Xhat_t_t))
            XR = Xhat_t_t([1,o1+1,o2+1]);
            pivot = 0;
        else
            return
        end
    end
else
    if (~isempty(Xhat_t_t))
        XR = Xhat_t_t([1,o1+1,o2+1]);
        pivot = 0;
    else
        return
    end
end

if isempty(cov_XR) %if it was not possible to compute the covariance matrix
    cov_XR = sigmaq0 * eye(3);
end
sigma2_XR = diag(cov_XR);

%do not use least squares ambiguity estimation
% NOTE: LS amb. estimation is automatically switched off if the number of
% satellites with phase available is not sufficient
if (length(sat) < 4)
    
    %ambiguity initialization: initialized value
    %if the satellite is visible, 0 if the satellite is not visible
    N1 = zeros(32,1);
    N2 = zeros(32,1);
    sigma2_N1 = zeros(32,1);
    sigma2_N2 = zeros(32,1);
    
    %computation of the phase double differences in order to estimate N
    if ~isempty(sat)
        [N1(sat), sigma2_N1(sat)] = amb_estimate_observ_SA(pr1(sat), ph1(sat), 1);
        [N2(sat), sigma2_N2(sat)] = amb_estimate_observ_SA(pr2(sat), ph2(sat), 2);
    end

    if (length(phase) == 2)
        N = [N1; N2];
        sigma2_N = [sigma2_N1; sigma2_N2];
    else
        if (phase == 1)
            N = N1;
            sigma2_N = sigma2_N1;
        else
            N = N2;
            sigma2_N = sigma2_N2;
        end
    end

%use least squares ambiguity estimation
else
    
    %ambiguity initialization: initialized value
    %if the satellite is visible, 0 if the satellite is not visible
    N1 = zeros(32,1);
    N2 = zeros(32,1);

    %ROVER positioning improvement with code and phase double differences
    if ~isempty(sat)
        [XR, dtR, N1(sat), cov_XR, var_dtR, cov_N1, PDOP, HDOP, VDOP] = LS_SA_code_phase(XR, XS, pr1(sat_pr), ph1(sat_pr), snr(sat_pr), elR(sat_pr), distR(sat_pr), sat_pr, sat, dtS, err_tropo, err_iono, 1); %#ok<ASGLU>
        [ ~,   ~, N2(sat),      ~,       ~, cov_N2]                   = LS_SA_code_phase(XR, XS, pr2(sat_pr), ph2(sat_pr), snr(sat_pr), elR(sat_pr), distR(sat_pr), sat_pr, sat, dtS, err_tropo, err_iono, 2);
    end
    
    if isempty(cov_XR) %if it was not possible to compute the covariance matrix
        cov_XR = sigmaq0 * eye(3);
    end
    sigma2_XR = diag(cov_XR);
    
    if isempty(cov_N1) %if it was not possible to compute the covariance matrix
        cov_N1 = sigmaq0_N * eye(length(sat));
    end
    
    if isempty(cov_N2) %if it was not possible to compute the covariance matrix
        cov_N2 = sigmaq0_N * eye(length(sat));
    end
    
    if (length(phase) == 2)
        N = [N1; N2];
        sigma2_N(sat) = diag(cov_N1);
        %sigma2_N(sat) = (sigmaq_cod1 / lambda1^2) * ones(length(sat),1);
        sigma2_N(sat+nN) = diag(cov_N2);
        %sigma2_N(sat+nN) = (sigmaq_cod2 / lambda2^2) * ones(length(sat),1);
    else
        if (phase == 1)
            N = N1;
            sigma2_N(sat) = diag(cov_N1);
            %sigma2_N(sat) = (sigmaq_cod1 / lambda1^2) * ones(length(sat),1);
        else
            N = N2;
            sigma2_N(sat) = diag(cov_N2);
            %sigma2_N(sat) = (sigmaq_cod2 / lambda2^2) * ones(length(sat),1);
        end
    end
end

%initialization of the initial point with 6(positions and velocities) +
%32 or 64 (N combinations) variables
Xhat_t_t = [XR(1); Z_om_1; XR(2); Z_om_1; XR(3); Z_om_1; N];

%--------------------------------------------------------------------------------------------
% INITIAL STATE COVARIANCE MATRIX
%--------------------------------------------------------------------------------------------

%initial state covariance matrix
Cee(:,:) = zeros(o3+nN);
Cee(1,1) = sigma2_XR(1);
Cee(o1+1,o1+1) = sigma2_XR(2);
Cee(o2+1,o2+1) = sigma2_XR(3);
Cee(2:o1,2:o1) = sigmaq0 * eye(o1-1);
Cee(o1+2:o2,o1+2:o2) = sigmaq0 * eye(o1-1);
Cee(o2+2:o3,o2+2:o3) = sigmaq0 * eye(o1-1);
Cee(o3+1:o3+nN,o3+1:o3+nN) = diag(sigma2_N);
