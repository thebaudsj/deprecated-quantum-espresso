!
! Copyright (C) 2002-2005 Quantum-ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
#include "f_defs.h"
!
!----------------------------------------------------------------------------
SUBROUTINE compute_fes_grads( N_in, N_fin, stat )
  !----------------------------------------------------------------------------
  !
  USE kinds,              ONLY : DP
  USE constants,          ONLY : e2
  USE input_parameters,   ONLY : startingwfc, startingpot, diago_thr_init
  USE basis,              ONLY : startingwfc_ => startingwfc, &
                                 startingpot_ => startingpot
  USE coarsegrained_vars, ONLY : new_target, to_target, to_new_target, &
                                 dfe_acc, shake_nstep, fe_nstep
  USE path_variables,     ONLY : pos, pes, grad_pes, frozen, &
                                 num_of_images, istep_path, suspended_image
  USE constraints_module, ONLY : lagrange, target, init_constraint, &
                                 deallocate_constraint
  USE dynam,              ONLY : dt
  USE control_flags,      ONLY : conv_elec, istep, history, wg_set, &
                                 alpha0, beta0, ethr, pot_order,    &
                                 conv_ions, ldamped
  USE cell_base,          ONLY : alat, at, bg
  USE gvect,              ONLY : ngm, g, nr1, nr2, nr3, eigts1, eigts2, eigts3
  USE vlocal,             ONLY : strf
  USE ener,               ONLY : etot
  USE ions_base,          ONLY : nat, nsp, tau, ityp, if_pos
  USE path_formats,       ONLY : scf_fmt, scf_fmt_para
  USE io_files,           ONLY : prefix, tmp_dir, iunpath, iunaxsf, &
                                 iunupdate, exit_file, iunexit
  USE parser,             ONLY : int_to_char, delete_if_present
  USE constants,          ONLY : bohr_radius_angs
  USE io_global,          ONLY : stdout, ionode, ionode_id, meta_ionode
  USE mp_global,          ONLY : inter_image_comm, intra_image_comm, &
                                 my_image_id, nimage, root
  USE mp,                 ONLY : mp_bcast, mp_barrier, mp_sum, mp_min
  USE check_stop,         ONLY : check_stop_now
  USE path_io_routines,   ONLY : new_image_init, get_new_image, &
                                 stop_other_images  
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(IN)   :: N_in, N_fin
  LOGICAL, INTENT(OUT)  :: stat
  INTEGER               :: image, iter
  REAL(DP)              :: tcpu, error
  CHARACTER(LEN=256)    :: tmp_dir_saved, filename
  LOGICAL               :: opnd, file_exists
  LOGICAL               :: lfirst, ldamped_saved
  REAL(DP), ALLOCATABLE :: tauold(:,:,:)
    ! previous positions of atoms (needed for extrapolation)
  !
  REAL(DP), EXTERNAL :: get_clock
  !
  !
  CALL flush_unit( iunpath )
  !
  ALLOCATE( tauold( 3, nat, 3 ) )
  !
  IF ( ionode ) THEN
     !
     OPEN( UNIT = iunaxsf, FILE = TRIM( prefix ) // "_" // &
         & TRIM( int_to_char( istep_path + 1 ) ) // ".axsf", &
           STATUS = "UNKNOWN", ACTION = "WRITE" )
     !
     WRITE( UNIT = iunaxsf, FMT = '(" ANIMSTEPS ",I5)' ) num_of_images
     WRITE( UNIT = iunaxsf, FMT = '(" CRYSTAL ")' )
     WRITE( UNIT = iunaxsf, FMT = '(" PRIMVEC ")' )
     WRITE( UNIT = iunaxsf, FMT = '(3F14.10)' ) &
          at(1,1) * alat * bohr_radius_angs, &
          at(2,1) * alat * bohr_radius_angs, &
          at(3,1) * alat * bohr_radius_angs
     WRITE( UNIT = iunaxsf, FMT = '(3F14.10)' ) &
          at(1,2) * alat * bohr_radius_angs, &
          at(2,2) * alat * bohr_radius_angs, &
          at(3,2) * alat * bohr_radius_angs
     WRITE( UNIT = iunaxsf, FMT = '(3F14.10)' ) &
          at(1,3) * alat * bohr_radius_angs, &
          at(2,3) * alat * bohr_radius_angs, &
          at(3,3) * alat * bohr_radius_angs
     !
  END IF
  !
  tmp_dir_saved = tmp_dir
  ldamped_saved = ldamped
  !
  ! ... vectors pes and grad_pes are initalized to zero for all images on
  ! ... all nodes: this is needed for the final mp_sum()
  !
  IF ( my_image_id == root ) THEN
     !
     FORALL( image = N_in:N_fin, .NOT. frozen(image)   )
        !
        grad_pes(:,image) = 0.D0
        !
     END FORALL     
     !
  ELSE
     !
     grad_pes(:,N_in:N_fin) = 0.D0
     !   
  END IF
  !
  ! ... only the first cpu initializes the file needed by parallelization 
  ! ... among images
  !
  IF ( meta_ionode ) CALL new_image_init( N_in, tmp_dir_saved )
  !
  image = N_in + my_image_id
  !
  ! ... all processes are syncronized (needed to have an ordered output)
  !
  CALL mp_barrier()
  !
  fes_loop: DO
     !
     ! ... exit if available images are finished
     !
     IF ( image > N_fin ) EXIT fes_loop
     !     
     suspended_image = image
     !
     IF ( check_stop_now( iunpath ) ) THEN
        !   
        stat = .FALSE.
        !
        ! ... in case of parallelization on images a stop signal
        ! ... is sent via the "EXIT" file
        !
        IF ( nimage > 1 ) CALL stop_other_images()        
        !
        EXIT fes_loop
        !    
     END IF
     !
     ! ... free-energy gradient ( for non-frozen images only )
     !
     IF ( .NOT. frozen(image) ) THEN
        !
        CALL clean_pw( .FALSE. )
        !
        tcpu = get_clock( 'PWSCF' )
        !
        IF ( nimage > 1 ) THEN
           !
           WRITE( UNIT = iunpath, FMT = scf_fmt_para ) my_image_id, tcpu, image
           !
        ELSE
           !
           WRITE( UNIT = iunpath, FMT = scf_fmt ) tcpu, image
           !
        END IF
        !
        tmp_dir = TRIM( tmp_dir_saved ) // TRIM( prefix ) // &
                  "_" // TRIM( int_to_char( image ) ) // "/"
        !
        ! ... unit stdout is connected to the appropriate file
        !
        IF ( ionode ) THEN
           !
           INQUIRE( UNIT = stdout, OPENED = opnd )
           IF ( opnd ) CLOSE( UNIT = stdout )
           OPEN( UNIT = stdout, FILE = TRIM( tmp_dir ) // 'PW.out', &
                 STATUS = 'UNKNOWN', POSITION = 'APPEND' )
           !
        END IF
        !
        ! ... we read the previous positions for this image from a restart file
        !
        filename = TRIM( tmp_dir ) // "thermodinamic_average.restart"
        !
        INQUIRE( FILE = filename, EXIST = file_exists )
        !
        IF ( file_exists ) THEN
           !
           OPEN( UNIT = 1000, FILE = filename )
           !
           READ( 1000, * ) tau
           !
           CLOSE( UNIT = 1000 )
           !
        END IF
        !
        CALL deallocate_constraint()
        CALL init_constraint( nat, tau, alat, ityp )
        !
        CALL init_run()
        !
        ! ... the old and new values of the order-parameter are set here
        !
        new_target(:) = pos(:,image)
        !
        IF ( ionode ) THEN
           !     
           ! ... the file containing old positions is opened 
           ! ... ( needed for extrapolation )
           !
           CALL seqopn( iunupdate, 'update', 'FORMATTED', file_exists ) 
           !
           IF ( file_exists ) THEN
              !
              READ( UNIT = iunupdate, FMT = * ) history
              READ( UNIT = iunupdate, FMT = * ) tauold
              !
           ELSE
              !
              history = 0
              tauold  = 0.D0
              !
              WRITE( UNIT = iunupdate, FMT = * ) history
              WRITE( UNIT = iunupdate, FMT = * ) tauold
              !
           END IF
           !
           CLOSE( UNIT = iunupdate, STATUS = 'KEEP' )
           !
        END IF
        !
        CALL mp_bcast( history, ionode_id, intra_image_comm )
        CALL mp_bcast( tauold,  ionode_id, intra_image_comm )
        !
        IF ( conv_elec .AND. history > 0 ) THEN
           !
           ! ... potential and wavefunctions are extrapolated only if
           ! ... we are starting a new self-consistency (scf on the 
           ! ... previous image was achieved)
           !
           IF ( ionode ) THEN 
              !
              ! ... find the best coefficients for the extrapolation of 
              ! ... the potential
              !
              CALL find_alpha_and_beta( nat, tau, tauold, alpha0, beta0 )        
              !
           END IF
           !
           CALL mp_bcast( alpha0, ionode_id, intra_image_comm )
           CALL mp_bcast( beta0,  ionode_id, intra_image_comm )                
           !
           IF ( pot_order > 0 ) THEN
              !
              ! ... structure factors of the old positions are computed 
              ! ... (needed for the old atomic charge)
              !
              CALL struc_fact( nat, tauold(:,:,1), nsp, ityp, ngm, g, bg, &
                               nr1, nr2, nr3, strf, eigts1, eigts2, eigts3 )
              !
           END IF
           !
           CALL update_pot()
           !
        END IF
        !
        wg_set = .FALSE.
        lfirst = .TRUE.
        !
        ! ... first the system is "adiabatically" moved to the new target
        ! ... by using MD without damping
        !
        to_target(:) = new_target(:) - target(:)
        !
        ldamped = .FALSE.
        !
        CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.md' )
        CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.update' )
        !
        to_new_target = .TRUE.
        !
        DO iter = 1, shake_nstep
           !
           istep = iter
           !
           CALL electronic_scf( lfirst, stat )
           !
           IF ( .NOT. stat ) RETURN
           !
           CALL move_ions()
           !
           lfirst = .FALSE.
           !
        END DO
        !
        ldamped = ldamped_saved
        !
        ! ... then the free energy gradients are computed
        !
        CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.md' )
        CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.bfgs' )
        !
        to_new_target = .FALSE.
        !
        DO iter = 1, fe_nstep
           !
           istep = iter
           !
           CALL electronic_scf( lfirst, stat )
           !
           IF ( .NOT. stat )  RETURN
           !
           CALL move_ions()
           !
           IF ( ldamped .AND. conv_ions ) EXIT
           !
           lfirst = .FALSE.
           !
        END DO
        !
        ! ... the averages are computed here (coverted ot Hartree a.u.)
        !
        IF ( ldamped ) THEN
           !
           ! ... zero temperature
           !
           grad_pes(:,image) = - lagrange(:) / e2
           !
           pes(image) = etot / e2
           !
        ELSE
           !
           ! ... finite temperature
           !
           grad_pes(:,image) = dfe_acc(:) / DBLE( istep ) / e2
           !
        END IF
        !
        IF ( ionode ) THEN
           !
           ! ... save the previous two steps 
           ! ... ( a total of three ionic steps is saved )
           !
           tauold(:,:,3) = tauold(:,:,2)
           tauold(:,:,2) = tauold(:,:,1)
           tauold(:,:,1) = tau(:,:)              
           !
           history = MIN( 3, ( history + 1 ) )
           !
           CALL seqopn( iunupdate, 'update', 'FORMATTED', file_exists ) 
           !
           WRITE( UNIT = iunupdate, FMT = * ) history
           WRITE( UNIT = iunupdate, FMT = * ) tauold
           !
           CLOSE( UNIT = iunupdate, STATUS = 'KEEP' )
           !
        END IF
        !
        IF ( ionode ) CALL write_config( image )
        !
        ! ... the restart file is written here
        !
        OPEN( UNIT = 1000, FILE = filename )
        !
        WRITE( 1000, * ) tau
        !
        CLOSE( UNIT = 1000 )
        !
     END IF
     !
     ! ... the new image is obtained (by ionode only)
     !
     CALL get_new_image( image, tmp_dir_saved )
     !
     CALL mp_bcast( image, ionode_id, intra_image_comm )
     !        
     ! ... input values are restored at the end of each iteration ( they are
     ! ... modified in init_run )
     !
     startingpot_ = startingpot
     startingwfc_ = startingwfc
     !
     ethr = diago_thr_init
     !
     CALL close_files()
     !
     CALL reset_k_points()
     !
  END DO fes_loop
  !
  CLOSE( UNIT = iunaxsf )
  !
  DEALLOCATE( tauold )
  !
  tmp_dir = tmp_dir_saved
  !
  IF ( nimage > 1 ) THEN
     !
     ! ... grad_pes is communicated among "image" pools
     !
     CALL mp_sum( grad_pes(:,N_in:N_fin), inter_image_comm )
     !
  END IF
  !
  ! ... after the lfirst call to compute_scf the input values of startingpot
  ! ... and startingwfc are both set to 'file'
  !
  startingpot = 'file'
  startingwfc = 'file'
  startingpot_ = startingpot
  startingwfc_ = startingwfc
  !
  RETURN  
  !
END SUBROUTINE compute_fes_grads
!
!------------------------------------------------------------------------
SUBROUTINE metadyn()
  !------------------------------------------------------------------------
  !
  USE kinds,              ONLY : DP
  USE constants,          ONLY : eps8
  USE constraints_module, ONLY : nconstr, target
  USE ener,               ONLY : etot
  USE io_files,           ONLY : iunaxsf, iunmeta
  USE coarsegrained_vars, ONLY : fe_grad, new_target, to_target, metadyn_fmt, &
                                 to_new_target, fe_step, metadyn_history, &
                                 max_metadyn_iter, starting_metadyn_iter, &
                                 gaussian_add, gaussian_add_iter
  USE coarsegrained_base, ONLY : add_gaussians
  USE io_global,          ONLY : ionode, stdout
  USE basic_algebra_routines
  !
  IMPLICIT NONE
  !
  INTEGER  :: iter, i
  REAL(DP) :: norm_fe_grad
  !
  REAL(DP), EXTERNAL :: rndm
  !
  !
  iter = starting_metadyn_iter
  !
  metadyn_loop: DO
     !
     IF ( iter > 0 ) THEN
        !
        CALL add_gaussians( iter )
        !
        norm_fe_grad = norm( fe_grad )
        !
        IF ( norm_fe_grad < eps8 ) THEN
           !
           ! ... use a random perturbation (just in case we start very close
           ! ... to the minimum)
           !
           WRITE( iunmeta, '("random step")' )
           !
           DO i = 1, nconstr
              !
              fe_grad(:) = rndm()
              !
           END DO
           !
           norm_fe_grad = norm( fe_grad )
           !
        END IF
        !
        new_target(:) = target(:) - fe_step(:) * fe_grad(:) / norm_fe_grad
        !
        WRITE( stdout, '(/,5X,"adiabatic switch of the system ", &
                            & "to the new coarse-grained positions",/)' )
        !
        ! ... the system is "adiabatically" moved to the new target
        !
        CALL move_to_target()
        !
     END IF
     !
     iter = iter + 1
     !
     metadyn_history(:,iter) = target(:)
     !
     gaussian_add(iter) = ( MOD( iter - 1, gaussian_add_iter ) == 0 )
     !
     IF ( ionode ) CALL write_config( iter )
     !
     WRITE( stdout, '(/,5X,"calculation of the potential of mean force",/)' )
     !
     CALL free_energy_grad( iter )
     !
     IF ( ionode ) THEN
        !
        WRITE( iunmeta, metadyn_fmt ) &
            iter, target(:), etot, fe_grad(:), gaussian_add(iter)
        !
     END IF
     !
     IF ( ionode ) CALL flush_unit( iunmeta )
     IF ( ionode ) CALL flush_unit( iunaxsf )
     !
     IF ( iter >= max_metadyn_iter ) EXIT metadyn_loop
     !
  END DO metadyn_loop
  !
  IF ( ionode ) THEN
     !
     CALL write_config( iter )
     !
     CLOSE( UNIT = iunaxsf )
     CLOSE( UNIT = iunmeta )
     !
  END IF
  !
  RETURN
  !
  CONTAINS
    !
    !------------------------------------------------------------------------
    SUBROUTINE free_energy_grad( iter )
      !------------------------------------------------------------------------
      !
      USE constants,          ONLY : e2
      USE control_flags,      ONLY : istep, ldamped, conv_ions
      USE coarsegrained_vars, ONLY : fe_nstep, dfe_acc
      USE constraints_module, ONLY : lagrange
      USE control_flags,      ONLY : istep, conv_ions
      USE io_files,           ONLY : tmp_dir, prefix
      USE parser,             ONLY : delete_if_present
      !
      IMPLICIT NONE
      !
      INTEGER, INTENT(IN) :: iter
      !
      LOGICAL :: stat
      LOGICAL :: lfirst = .TRUE.
      !
      !
      dfe_acc = 0.D0
      !
      CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.md' )
      CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.bfgs' )
      !
      to_new_target = .FALSE.
      !
      DO istep = 1, fe_nstep
         !
         CALL electronic_scf( lfirst, stat )
         !
         IF ( .NOT. stat ) CALL stop_run( stat )
         !
         CALL move_ions()
         !
         IF ( ldamped .AND. conv_ions ) EXIT
         !
         lfirst = .FALSE.
         !
      END DO
      !
      ! ... the averages are computed here
      !
      IF ( ldamped ) THEN
         !
         ! ... zero temperature
         !
         fe_grad(:) = - lagrange(:) / e2
         !
      ELSE
         !
         ! ... finite temperature
         !
         fe_grad(:) = dfe_acc(:) / DBLE( istep ) / e2
         !
      END IF
      !
      RETURN
      !
    END SUBROUTINE free_energy_grad
    !
    !------------------------------------------------------------------------
    SUBROUTINE move_to_target()
      !------------------------------------------------------------------------
      !
      USE coarsegrained_vars, ONLY : shake_nstep
      USE control_flags,      ONLY : istep, ldamped
      USE io_files,           ONLY : tmp_dir, prefix
      USE parser,             ONLY : delete_if_present
      !
      LOGICAL :: stat, ldamped_saved
      !
      !
      ldamped_saved = ldamped
      !
      to_target(:) = new_target(:) - target(:)
      !
      CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.md' )
      CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.update' )
      !
      ldamped       = .FALSE.
      to_new_target = .TRUE.
      !
      DO istep = 1, shake_nstep
         !
         CALL electronic_scf( .FALSE., stat )
         !
         IF ( .NOT. stat ) CALL stop_run( stat )
         !
         CALL delete_if_present( TRIM( tmp_dir ) // TRIM( prefix ) // '.bfgs' )
         !
         CALL move_ions()
         !
      END DO
      !
      ldamped = ldamped_saved
      !
      RETURN
      !
    END SUBROUTINE move_to_target
    !
END SUBROUTINE metadyn
!
!----------------------------------------------------------------------------
SUBROUTINE write_config( image )
  !----------------------------------------------------------------------------
  !
  USE input_parameters, ONLY : atom_label
  USE io_files,         ONLY : iunaxsf
  USE constants,        ONLY : bohr_radius_angs
  USE ions_base,        ONLY : nat, tau, ityp
  USE cell_base,        ONLY : alat
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(IN) :: image
  INTEGER             :: atom
  !
  !
  WRITE( UNIT = iunaxsf, FMT = '(" PRIMCOORD ",I5)' ) image
  WRITE( UNIT = iunaxsf, FMT = '(I5,"  1")' ) nat
  !
  DO atom = 1, nat
     !
     WRITE( UNIT = iunaxsf, FMT = '(A2,3(2X,F18.10))' ) &
            TRIM( atom_label(ityp(atom)) ), &
         tau(1,atom) * alat * bohr_radius_angs, &
         tau(2,atom) * alat * bohr_radius_angs, &
         tau(3,atom) * alat * bohr_radius_angs
     !
  END DO
  !
  RETURN
  !
END SUBROUTINE write_config
!
!----------------------------------------------------------------------------
SUBROUTINE electronic_scf( lfirst, stat )
  !----------------------------------------------------------------------------
  !
  USE control_flags, ONLY : conv_elec, ethr
  USE io_files,      ONLY : iunpath
  !
  IMPLICIT NONE
  !
  LOGICAL, INTENT(IN)  :: lfirst
  LOGICAL, INTENT(OUT) :: stat
  !
  !
  IF ( .NOT. lfirst ) THEN
     !
     ethr = 1.D-5
     !
     CALL hinit1()
     !
  END IF
  !
  CALL electrons()
  !
  stat = conv_elec
  !
  IF ( .NOT. conv_elec ) THEN
     !
     WRITE( UNIT = iunpath, &
            FMT = '(/,5X,"WARNING :  scf convergence NOT achieved",/)' )
     !
     RETURN
     !
  END IF
  !
  CALL forces()
  !
  RETURN
  !
END SUBROUTINE electronic_scf
